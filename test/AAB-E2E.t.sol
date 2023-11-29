// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.21;

import {console2} from "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";
import {DAOMock} from "@aragon/osx/test/dao/DAOMock.sol";
import {IPluginSetup} from "@aragon/osx/framework/plugin/setup/PluginSetup.sol";
import {DaoUnauthorized} from "@aragon/osx/core/utils/auth.sol";
import {IMajorityVoting} from "@aragon/osx/plugins/governance/majority-voting/IMajorityVoting.sol";

import {AragonTest} from "./base/AragonTest.sol";
import {IPluginSetup, PluginSetup} from "@aragon/osx/framework/plugin/setup/PluginSetup.sol";

import {ILayerZeroSender} from "../src/interfaces/ILayerZeroSender.sol";

import {ParentBridge} from "../src/ParentBridge.sol";
import {ParentBridgeSetup} from "../src/ParentBridgeSetup.sol";
import {ChildBridge} from "../src/ChildBridge.sol";
import {ChildBridgeSetup} from "../src/ChildBridgeSetup.sol";

import {LZEndpointMock} from "./mocks/LayerZeroBridgeMock.sol";
import {MockToken} from "./mocks/MockToken.sol";

abstract contract AABBase is AragonTest {
    DAO internal parentDao;
    DAO internal childDao;

    ParentBridge internal parentBridgePlugin;
    ParentBridgeSetup internal parentSetup;

    ChildBridge internal childBridgePlugin;
    ChildBridgeSetup internal childSetup;

    LZEndpointMock polygonBridge;
    LZEndpointMock mainnetBridge;

    MockToken internal weth;

    address bob = address(0xb0b);
    address dad = address(0xdad);
    address dead = address(0xdead);

    function setUp() public virtual {
        polygonBridge = new LZEndpointMock(137);
        mainnetBridge = new LZEndpointMock(1);
        console2.log("polygonBridge", address(polygonBridge));
        console2.log("mainnetBridge", address(mainnetBridge));

        weth = new MockToken("Wraped Ether", "WETH");
        vm.label(address(weth), "WETH");
        vm.label(address(polygonBridge), "PolygonBridge");
        vm.label(address(mainnetBridge), "MainnetBridge");

        setupChild();
        setupParent();
        postSetup();
    }

    function setupParent() public virtual {
        ParentBridge.BridgeSettings memory parentBridgeSettings = ParentBridge.BridgeSettings({
            chainId: 1, // child is on mainnet
            bridge: address(polygonBridge), // we are on polygon
            childDAO: address(childDao), // child dao
            childPlugin: address(childBridgePlugin) // child plugin
        });

        parentSetup = new ParentBridgeSetup();
        bytes memory setupData = parentSetup.encodeSetupData(parentBridgeSettings);

        (DAO _parentDao, address _plugin) = createMockDaoWithPlugin(parentSetup, setupData);

        parentDao = _parentDao;
        parentBridgePlugin = ParentBridge(_plugin);
        vm.deal(address(parentDao), 100 ether);
        vm.label(address(parentDao), "ParentDAO");
        vm.label(address(parentBridgePlugin), "ParentBridgePlugin");
    }

    function setupChild() public virtual {
        childSetup = new ChildBridgeSetup();
        bytes memory setupData = childSetup.encodeSetupData(mainnetBridge);

        (DAO _childDao, address _plugin) = createMockDaoWithPlugin(childSetup, setupData);
        childDao = _childDao;
        childBridgePlugin = ChildBridge(_plugin);

        vm.label(address(childDao), "ChildDAO");
        vm.label(address(childBridgePlugin), "ChildBridgePlugin");
    }

    function postSetup() public virtual {
        vm.prank(address(childDao));

        childBridgePlugin.setParentPluginBridge({
            _parentPluginBridge: address(parentBridgePlugin),
            _remoteChainId: 137
        });

        weth.mint(address(childDao), 100 ether);

        // the child dao is on mainnet
        mainnetBridge.setDestLzEndpoint(address(parentBridgePlugin), address(polygonBridge));
        polygonBridge.setDestLzEndpoint(address(childBridgePlugin), address(mainnetBridge));
    }
}

contract AAB_InitTests is AABBase {
    function test_initialize() public {
        assertEq(address(parentBridgePlugin.dao()), address(parentDao));
        assertEq(address(childBridgePlugin.dao()), address(childDao));
        assertEq(address(childBridgePlugin.parentBridgePlugin()), address(parentBridgePlugin));
    }

    function test_reverts_if_reinitialized() public {
        ParentBridge.BridgeSettings memory parentBridgeSettings = ParentBridge.BridgeSettings({
            chainId: 1, // child is on mainnet
            bridge: address(mainnetBridge), // we are on polygon
            childDAO: address(childDao), // child dao
            childPlugin: address(childBridgePlugin) // child plugin
        });

        vm.expectRevert("Initializable: contract is already initialized");
        parentBridgePlugin.initialize(parentDao, parentBridgeSettings);

        vm.expectRevert("Initializable: contract is already initialized");
        childBridgePlugin.initialize(childDao, polygonBridge);
    }
}

contract AAB_ExecuteChildFromParent is AABBase {
    function test_execute_child() public {
        IDAO.Action[] memory actions = new IDAO.Action[](1);
        actions[0] = IDAO.Action({
            to: address(weth),
            value: 0,
            data: abi.encodeCall(ERC20.transfer, (bob, 10 ether))
        });

        console2.log("parentDao", address(parentDao));
        console2.log("this contract", address(this));
        vm.startPrank(address(parentDao));
        // This is on polygon(parent) sending to mainnet (child)
        parentBridgePlugin.bridgeAction{value: 0.5 ether}({
            _metadata: abi.encodePacked("Transfer 10 WETH to Bob"),
            _actions: actions,
            _allowFailureMap: 0
        });
        vm.stopPrank();

        assertEq(weth.balanceOf(bob), 10 ether);
    }
}
