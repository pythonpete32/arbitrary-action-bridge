// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import { IDAO } from "@aragon/osx/core/dao/IDAO.sol";
import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { PermissionLib } from "@aragon/osx/core/permission/PermissionLib.sol";
import { PluginSetup, IPluginSetup } from "@aragon/osx/framework/plugin/setup/PluginSetup.sol";

import { ILayerZeroEndpoint } from "./interfaces/ILayerZeroEndpoint.sol";
import { ChildBridge } from "./ChildBridge.sol";

contract L2TokenVotingSetup is PluginSetup {
    using Address for address;
    using Clones for address;
    using ERC165Checker for address;

    /// @notice The address of the `ChildBridge` base contract.
    ChildBridge private immutable childBridgeBase;

    /// @inheritdoc IPluginSetup
    function prepareInstallation(
        address _dao,
        bytes calldata _data
    )
        external
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        (ILayerZeroEndpoint lzBridge, address parentDAO) = abi.decode(_data, (ILayerZeroEndpoint, address));

        plugin = createERC1967Proxy(
            address(childBridgeBase), abi.encodeCall(ChildBridge.initialize, (IDAO(_dao), lzBridge, parentDAO))
        );

        PermissionLib.MultiTargetPermission[] memory permissions = new PermissionLib.MultiTargetPermission[](1);

        permissions[0] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: _dao,
            who: plugin,
            condition: PermissionLib.NO_CONDITION,
            permissionId: DAO(payable(_dao)).EXECUTE_PERMISSION_ID()
        });

        preparedSetupData.permissions = permissions;
    }

    /// @inheritdoc IPluginSetup
    function prepareUninstallation(
        address _dao,
        SetupPayload calldata _payload
    )
        external
        view
        returns (PermissionLib.MultiTargetPermission[] memory permissions)
    {
        permissions = new PermissionLib.MultiTargetPermission[](1);

        permissions[0] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: _dao,
            who: _payload.plugin,
            condition: PermissionLib.NO_CONDITION,
            permissionId: DAO(payable(_dao)).EXECUTE_PERMISSION_ID()
        });
    }

    /// @inheritdoc IPluginSetup
    function implementation() external view virtual override returns (address) {
        return address(childBridgeBase);
    }

    function encodeSettings(ILayerZeroEndpoint lzBridge, address parentDAO) external pure returns (bytes memory) {
        return abi.encode(lzBridge, parentDAO);
    }
}
