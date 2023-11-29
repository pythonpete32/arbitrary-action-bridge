// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.21;

import {PluginUUPSUpgradeable} from "@aragon/osx/core/plugin/PluginUUPSUpgradeable.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";

import {NonblockingLzApp} from "./lzApp/NonblockingLzApp.sol";
import {ILayerZeroEndpoint} from "./interfaces/ILayerZeroEndpoint.sol";

contract ChildBridge is PluginUUPSUpgradeable, NonblockingLzApp {
    bytes32 public constant SET_PARENT_DAO_ROLE = keccak256("SET_PARENT_DAO_ROLE");

    address public parentDao;

    function initialize(IDAO _dao, ILayerZeroEndpoint lzBridge) external initializer {
        __PluginUUPSUpgradeable_init(_dao);

        _setEndpoint(address(lzBridge));
        bytes memory remoteAndLocalAddresses = abi.encodePacked(parentDao, address(this));
        _setTrustedRemoteAddress(1, remoteAndLocalAddresses);
    }

    function setParentDao(address _parentDao) external auth(SET_PARENT_DAO_ROLE) {
        parentDao = _parentDao;
    }

    function _nonblockingLzReceive(
        uint16,
        bytes memory,
        uint64,
        bytes memory _payload
    ) internal override {
        (
            IDAO.Action[] memory actions,
            uint256 allowFailureMap,
            bytes memory metadata,
            uint256 actionId
        ) = abi.decode(_payload, (IDAO.Action[], uint256, bytes, uint256));

        dao().execute({
            _callId: keccak256(abi.encode(actions, metadata, actionId)),
            _actions: actions,
            _allowFailureMap: allowFailureMap
        });
    }
}
