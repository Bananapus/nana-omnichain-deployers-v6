// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

contract ProjectIdFrontRunDoSTest is Test {
    function test_vulnerableCountBasedOmnichainLaunchCanBeFrontRun() public {
        MockProjects projects = new MockProjects(8, 10);
        MockController controller = new MockController(10);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        VulnerableOmnichainDeployerHarness harness = new VulnerableOmnichainDeployerHarness(projects, hookDeployer);

        vm.expectRevert(bytes("JBOmnichainDeployer_ProjectIdMismatch"));
        harness.launchProjectFor(controller);
    }

    function test_reservedOmnichainProjectIdCannotBeInvalidatedByEarlierCreations() public {
        MockProjects projects = new MockProjects(8, 10);
        MockController controller = new MockController(10);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        FixedOmnichainDeployerHarness harness = new FixedOmnichainDeployerHarness(projects, hookDeployer);

        uint256 projectId = harness.launchProjectFor(controller);

        assertEq(projectId, 10);
        assertEq(projects.lastOwner(), address(harness));
        assertEq(controller.lastLaunchedProjectId(), 10);
        assertEq(hookDeployer.lastHookProjectId(), 10);
    }
}

contract VulnerableOmnichainDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockHookDeployer internal immutable HOOK_DEPLOYER;

    constructor(MockProjects projects, MockHookDeployer hookDeployer) {
        PROJECTS = projects;
        HOOK_DEPLOYER = hookDeployer;
    }

    function launchProjectFor(MockController controller) external returns (uint256 projectId) {
        projectId = PROJECTS.count() + 1;
        HOOK_DEPLOYER.deployHookFor(projectId);

        if (projectId != controller.launchProjectFor()) revert("JBOmnichainDeployer_ProjectIdMismatch");
    }
}

contract FixedOmnichainDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockHookDeployer internal immutable HOOK_DEPLOYER;

    constructor(MockProjects projects, MockHookDeployer hookDeployer) {
        PROJECTS = projects;
        HOOK_DEPLOYER = hookDeployer;
    }

    function launchProjectFor(MockController controller) external returns (uint256 projectId) {
        projectId = PROJECTS.createFor(address(this));
        HOOK_DEPLOYER.deployHookFor(projectId);
        controller.launchRulesetsFor(projectId);
    }
}

contract MockProjects {
    uint256 internal immutable _count;
    uint256 internal immutable _reservedId;

    address public lastOwner;

    constructor(uint256 count_, uint256 reservedId_) {
        _count = count_;
        _reservedId = reservedId_;
    }

    function count() external view returns (uint256) {
        return _count;
    }

    function createFor(address owner) external returns (uint256) {
        lastOwner = owner;
        return _reservedId;
    }
}

contract MockController {
    uint256 internal immutable _launchedId;

    constructor(uint256 launchedId_) {
        _launchedId = launchedId_;
    }

    function launchProjectFor() external view returns (uint256) {
        return _launchedId;
    }

    uint256 public lastLaunchedProjectId;

    function launchRulesetsFor(uint256 projectId) external {
        require(projectId == _launchedId, "BAD_PROJECT_ID");
        lastLaunchedProjectId = projectId;
    }
}

contract MockHookDeployer {
    uint256 public lastHookProjectId;

    function deployHookFor(uint256 projectId) external {
        lastHookProjectId = projectId;
    }
}
