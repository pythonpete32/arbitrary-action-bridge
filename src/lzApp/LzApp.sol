// SPDX-License-Identifier: MIT

pragma solidity >=0.8.17;

import {console2} from "forge-std/console2.sol";

import {ILayerZeroReceiver} from "../interfaces/ILayerZeroReceiver.sol";
import {ILayerZeroEndpoint} from "../interfaces/ILayerZeroEndpoint.sol";
import {ILayerZeroUserApplicationConfig} from "../interfaces/ILayerZeroUserApplicationConfig.sol";
import {BytesLib} from "../utils/BytesLib.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/*
 * a generic LzReceiver implementation
 */
abstract contract LzApp is OwnableUpgradeable, ILayerZeroReceiver, ILayerZeroUserApplicationConfig {
    using BytesLib for bytes;

    // ua can not send payload larger than this by default, but it can be changed by the ua owner
    uint public constant DEFAULT_PAYLOAD_SIZE_LIMIT = 10000;

    uint public constant REQUIRED_ADAPTER_PARAM_LENGTH = 34;

    ILayerZeroEndpoint public lzEndpoint;
    mapping(uint16 => bytes) public trustedRemoteLookup;
    mapping(uint16 => mapping(uint16 => uint)) public minDstGasLookup;
    mapping(uint16 => uint) public payloadSizeLimitLookup;
    address public precrime;

    error InvalidSendingSource(address trusted, address actual);
    error InvalidEndpointCaller(address expected, address actual);
    error DestinationChainNotTrusted(uint16 dstChainId);
    error GasLimitTooLow(uint256 provided, uint256 required);
    error InvalidAdapterParams(uint256 requiredLength, uint256 providedLength);
    error PayloadSizeTooLarge(uint256 allowed, uint256 provided);
    error MinGasLimitNotSet();

    event SetPrecrime(address precrime);
    event SetTrustedRemote(uint16 _remoteChainId, bytes _path);
    event SetTrustedRemoteAddress(uint16 _remoteChainId, bytes _remoteAddress);
    event SetMinDstGas(uint16 _dstChainId, uint16 _type, uint _minDstGas);

    function _setEndpoint(address _endpoint) internal {
        lzEndpoint = ILayerZeroEndpoint(_endpoint);
    }

    function lzReceive(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public virtual override {
        // lzReceive must be called by the endpoint for security
        if (_msgSender() != address(lzEndpoint)) {
            revert InvalidEndpointCaller({expected: address(lzEndpoint), actual: _msgSender()});
        }

        bytes memory trustedRemote = trustedRemoteLookup[_srcChainId];
        // if will still block the message pathway from (srcChainId, srcAddress). should not receive message from untrusted remote.
        if (
            _srcAddress.length != trustedRemote.length ||
            trustedRemote.length <= 0 ||
            keccak256(_srcAddress) != keccak256(trustedRemote)
        ) {
            revert InvalidSendingSource({
                trusted: bytesToAddress(trustedRemote),
                actual: bytesToAddress(_srcAddress)
            });
        }

        _blockingLzReceive(_srcChainId, _srcAddress, _nonce, _payload);
    }

    // abstract function - the default behaviour of LayerZero is blocking. See: NonblockingLzApp if you dont need to enforce ordered messaging
    function _blockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual;

    function _lzSend(
        uint16 _dstChainId,
        bytes memory _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes memory _adapterParams,
        uint _nativeFee
    ) internal virtual {
        bytes memory trustedRemote = trustedRemoteLookup[_dstChainId];
        if (trustedRemote.length == 0) {
            revert DestinationChainNotTrusted(_dstChainId);
        }
        _checkPayloadSize(_dstChainId, _payload.length);
        lzEndpoint.send{value: _nativeFee}(
            _dstChainId,
            trustedRemote,
            _payload,
            _refundAddress,
            _zroPaymentAddress,
            _adapterParams
        );
    }

    function _checkGasLimit(
        uint16 _dstChainId,
        uint16 _type,
        bytes memory _adapterParams,
        uint _extraGas
    ) internal view virtual {
        uint providedGasLimit = _getGasLimit(_adapterParams);
        uint minGasLimit = minDstGasLookup[_dstChainId][_type];
        if (minGasLimit == 0) {
            revert MinGasLimitNotSet();
        }
        if (providedGasLimit < minGasLimit + _extraGas) {
            revert GasLimitTooLow({provided: providedGasLimit, required: minGasLimit + _extraGas});
        }
    }

    function _getGasLimit(
        bytes memory _adapterParams
    ) internal pure virtual returns (uint gasLimit) {
        if (_adapterParams.length < REQUIRED_ADAPTER_PARAM_LENGTH) {
            revert InvalidAdapterParams({
                requiredLength: REQUIRED_ADAPTER_PARAM_LENGTH,
                providedLength: _adapterParams.length
            });
        }
        assembly {
            gasLimit := mload(add(_adapterParams, 34))
        }
    }

    function _checkPayloadSize(uint16 _dstChainId, uint _payloadSize) internal view virtual {
        uint payloadSizeLimit = payloadSizeLimitLookup[_dstChainId];
        if (payloadSizeLimit == 0) {
            // use default if not set
            payloadSizeLimit = DEFAULT_PAYLOAD_SIZE_LIMIT;
        }
        if (_payloadSize > payloadSizeLimit) {
            revert PayloadSizeTooLarge({allowed: payloadSizeLimit, provided: _payloadSize});
        }
    }

    //---------------------------UserApplication config----------------------------------------
    function getConfig(
        uint16 _version,
        uint16 _chainId,
        address,
        uint _configType
    ) external view returns (bytes memory) {
        return lzEndpoint.getConfig(_version, _chainId, address(this), _configType);
    }

    // generic config for LayerZero user Application
    function setConfig(
        uint16 _version,
        uint16 _chainId,
        uint _configType,
        bytes calldata _config
    ) external override onlyOwner {
        lzEndpoint.setConfig(_version, _chainId, _configType, _config);
    }

    function setSendVersion(uint16 _version) external override onlyOwner {
        lzEndpoint.setSendVersion(_version);
    }

    function setReceiveVersion(uint16 _version) external override onlyOwner {
        lzEndpoint.setReceiveVersion(_version);
    }

    function forceResumeReceive(
        uint16 _srcChainId,
        bytes calldata _srcAddress
    ) external override onlyOwner {
        lzEndpoint.forceResumeReceive(_srcChainId, _srcAddress);
    }

    // this function set the trusted path for the cross-chain communication
    function setTrustedRemote(uint16 _remoteChainId, bytes calldata _path) external onlyOwner {
        trustedRemoteLookup[_remoteChainId] = _path;
        emit SetTrustedRemote(_remoteChainId, _path);
    }

    function _setTrustedRemoteAddress(uint16 _remoteChainId, bytes memory _remoteAddress) internal {
        trustedRemoteLookup[_remoteChainId] = _remoteAddress;
        emit SetTrustedRemoteAddress(_remoteChainId, _remoteAddress);
    }

    function getTrustedRemoteAddress(uint16 _remoteChainId) external view returns (bytes memory) {
        bytes memory path = trustedRemoteLookup[_remoteChainId];
        if (path.length == 0) {
            revert DestinationChainNotTrusted(_remoteChainId);
        }
        return path.slice(0, path.length - 20); // the last 20 bytes should be address(this)
    }

    function setPrecrime(address _precrime) external onlyOwner {
        precrime = _precrime;
        emit SetPrecrime(_precrime);
    }

    function setMinDstGas(uint16 _dstChainId, uint16 _packetType, uint _minGas) external onlyOwner {
        minDstGasLookup[_dstChainId][_packetType] = _minGas;
        emit SetMinDstGas(_dstChainId, _packetType, _minGas);
    }

    // if the size is 0, it means default size limit
    function setPayloadSizeLimit(uint16 _dstChainId, uint _size) external onlyOwner {
        payloadSizeLimitLookup[_dstChainId] = _size;
    }

    //--------------------------- VIEW FUNCTION ----------------------------------------
    function isTrustedRemote(
        uint16 _srcChainId,
        bytes calldata _srcAddress
    ) external view returns (bool) {
        bytes memory trustedSource = trustedRemoteLookup[_srcChainId];
        return keccak256(trustedSource) == keccak256(_srcAddress);
    }
}

function bytesToAddress(bytes memory bys) pure returns (address addr) {
    assembly {
        addr := mload(add(bys, 20))
    }
}
