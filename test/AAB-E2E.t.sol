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

    ParentBridge internal parentBridge;
    ParentBridgeSetup internal parentSetup;

    ChildBridge internal childBridge;
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
        weth = new MockToken("Wraped Ether", "WETH");

        setupChild();
        setupParent();
        postSetup();
    }

    function setupParent() public virtual {
        ParentBridge.BridgeSettings memory parentBridgeSettings = ParentBridge.BridgeSettings({
            chainId: 1, // child is on mainnet
            bridge: address(mainnetBridge), // we are on polygon
            childDAO: address(childDao), // child dao
            childPlugin: address(childBridge) // child plugin
        });

        parentSetup = new ParentBridgeSetup();
        bytes memory setupData = parentSetup.encodeSetupData(parentBridgeSettings);

        (DAO _parentDao, address _plugin) = createMockDaoWithPlugin(parentSetup, setupData);
        parentDao = _parentDao;
        parentBridge = ParentBridge(_plugin);
    }

    function setupChild() public virtual {
        childSetup = new ChildBridgeSetup();
        bytes memory setupData = childSetup.encodeSetupData(polygonBridge);

        (DAO _childDao, address _plugin) = createMockDaoWithPlugin(childSetup, setupData);
        childDao = _childDao;
        childBridge = ChildBridge(_plugin);
    }

    function postSetup() public virtual {
        vm.prank(address(childDao));
        childBridge.setParentDao(address(parentDao));

        weth.mint(address(childDao), 100 ether);

        mainnetBridge.setDestLzEndpoint(address(parentBridge), address(polygonBridge));
        polygonBridge.setDestLzEndpoint(address(childBridge), address(mainnetBridge));
    }
}

contract AAB_InitTests is AABBase {
    function test_initialize() public {
        assertEq(address(parentBridge.dao()), address(parentDao));
        assertEq(address(childBridge.dao()), address(childDao));
        assertEq(address(childBridge.parentDao()), address(parentDao));
    }

    function test_reverts_if_reinitialized() public {
        ParentBridge.BridgeSettings memory parentBridgeSettings = ParentBridge.BridgeSettings({
            chainId: 1, // child is on mainnet
            bridge: address(mainnetBridge), // we are on polygon
            childDAO: address(childDao), // child dao
            childPlugin: address(childBridge) // child plugin
        });

        vm.expectRevert("Initializable: contract is already initialized");
        parentBridge.initialize(parentDao, parentBridgeSettings);

        vm.expectRevert("Initializable: contract is already initialized");
        childBridge.initialize(childDao, polygonBridge);
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

        vm.prank(address(parentDao));
        parentBridge.bridgeAction({
            _metadata: abi.encodePacked("Transfer 10 WETH to Bob"),
            _actions: actions,
            _allowFailureMap: 0
        });

        assertEq(weth.balanceOf(bob), 10 ether);
    }
}

//     function test_FirstProposalBeingBridged() public {
//         console2.log(address(dao));
//         console2.log(address(plugin));
//         console2.log(address(l2dao));
//         console2.log(address(l2plugin));
//         console2.log(address(l1Bridge));
//         console2.log(address(l2Bridge));
//         vm.startPrank(bob);
//         vm.warp(block.timestamp + 100);
//         vm.roll(block.number + 2);
//         bytes memory _metadata = abi.encodeWithSelector(
//             L1TokenVoting.updateBridgeSettings.selector,
//             uint16(1), // Or other chain really
//             address(l1Bridge),
//             address(l2dao),
//             address(l2plugin)
//         );
//         IDAO.Action[] memory _actions = new IDAO.Action[](0);
//         uint256 _allowFailureMap = 0;
//         uint64 _startDate = uint64(block.timestamp);
//         uint64 _endDate = uint64(block.timestamp + 5000);

//         L1MajorityVotingBase.VoteOption _voteOption = IMajorityVoting.VoteOption.Yes;
//         bool _tryEarlyExecution = true;
//         uint256 proposalId = plugin.createProposal{value: 0.5 ether}(
//             _metadata, _actions, _allowFailureMap, _startDate, _endDate, _voteOption, _tryEarlyExecution
//         );

//         assertEq(proposalId, uint256(1), "ProposalId is not correct");
//         vm.stopPrank();
//         vm.startPrank(dad);
//         l2plugin.vote(0, IL2MajorityVoting.VoteOption.Yes);
//         l2plugin.execute{value: 0.5 ether}(0);
//         vm.stopPrank();

//         (
//             bool open,
//             uint256 parentProposalId,
//             bool executed,
//             L2MajorityVotingBase.ProposalParameters memory parameters,
//             L2MajorityVotingBase.Tally memory tally
//         ) = l2plugin.getProposal(0);

//         assertEq(open, false);
//         assertEq(parentProposalId, uint256(1));
//         assertEq(tally.yes, 10 ether);
//     }
// }
