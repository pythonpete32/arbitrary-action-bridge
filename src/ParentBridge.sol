// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.17;

import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {PluginUUPSUpgradeable} from "@aragon/osx/core/plugin/PluginUUPSUpgradeable.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";

import {ILayerZeroSender} from "./interfaces/ILayerZeroSender.sol";
import {NonblockingLzApp} from "./lzApp/NonblockingLzApp.sol";

contract ParentBridge is PluginUUPSUpgradeable, NonblockingLzApp {
    using SafeCastUpgradeable for uint256;

    /// @notice The ID of the permission required to call the `updateBridgeSettings` function.
    bytes32 public constant UPDATE_BRIDGE_SETTINGS_PERMISSION_ID =
        keccak256("UPDATE_BRIDGE_SETTINGS_PERMISSION");

    /// @notice The ID of the permission required to call the `bridgeAction` function.
    bytes32 public constant BRIDGE_ROLE_ID = keccak256("BRIDGE_ROLE");

    /// @notice A container for the majority voting bridge settings that will be required when bridging and receiving
    /// the proposals from other chains
    /// @param chainID A parameter to select the id of the destination chain
    /// @param bridge A parameter to select the address of the bridge you want to interact with
    /// @param childDAO A parameter to select the address of the DAO you want to interact with in the destination chain
    /// @param childPlugin A parameter to select the address of the plugin you want to interact with in the destination
    /// chain
    struct BridgeSettings {
        uint16 chainId;
        address bridge;
        address childDAO;
        address childPlugin;
    }

    /// @notice The struct storing the bridge settings.
    BridgeSettings public bridgeSettings;

    /// @notice The ID of the actions bridged over to the Child DAO.
    uint256 public actionsId;

    /// @notice bridge is not yet set
    error BridgeSettingsNotSet();

    /// @notice Bridge settings are invalid
    error InvalidBridgeSettings(BridgeSettings bridgeSettings);

    event ActionBridged(
        uint256 indexed actionsId,
        IDAO.Action[] actions,
        uint256 indexed allowFailureMap,
        bytes metadata
    );

    /// @notice Initializes the component.
    /// @dev This method is required to support [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822).
    /// @param _dao The IDAO interface of the associated DAO.
    function initialize(IDAO _dao, BridgeSettings memory _bridgeSettings) external initializer {
        if (
            _bridgeSettings.bridge == address(0) ||
            _bridgeSettings.chainId == uint16(0) ||
            _bridgeSettings.childDAO == address(0) ||
            _bridgeSettings.childPlugin == address(0)
        ) {
            revert BridgeSettingsNotSet();
        }
        __PluginUUPSUpgradeable_init(_dao);
        bridgeSettings = _bridgeSettings;

        actionsId = 1;
    }

    function bridgeAction(
        bytes calldata _metadata,
        IDAO.Action[] calldata _actions,
        uint256 _allowFailureMap
    ) external payable auth(BRIDGE_ROLE_ID) {
        // Bridge the proposal over to the L2
        bytes memory encodedMessage = abi.encode(
            _actions,
            _allowFailureMap,
            _metadata,
            actionsId++
        );

        if (
            bridgeSettings.bridge != address(0) ||
            bridgeSettings.chainId != uint16(0) ||
            address(bridgeSettings.childDAO) != address(0)
        ) {
            _lzSend({
                _dstChainId: bridgeSettings.chainId,
                _payload: encodedMessage,
                _refundAddress: payable(msg.sender),
                _zroPaymentAddress: address(0),
                _adapterParams: bytes(""),
                _nativeFee: address(this).balance
            });

            emit ActionBridged(actionsId, _actions, _allowFailureMap, _metadata);
        }
    }

    /// @notice Updates the bridge settings.
    /// @param _bridgeSettings The new voting settings.
    function updateBridgeSettings(
        BridgeSettings calldata _bridgeSettings
    ) external virtual auth(UPDATE_BRIDGE_SETTINGS_PERMISSION_ID) {
        bridgeSettings = _bridgeSettings;
        _setEndpoint(_bridgeSettings.bridge);
        bytes memory remoteAndLocalAddresses = abi.encodePacked(
            _bridgeSettings.childPlugin,
            address(this)
        );
        _setTrustedRemoteAddress(_bridgeSettings.chainId, remoteAndLocalAddresses);
    }

    function _nonblockingLzReceive(
        uint16 /*_srcChainId*/,
        bytes memory /*_srcAddress*/,
        uint64 /*_nonce*/,
        bytes memory /*_pyload*/
    ) internal override {}
}
