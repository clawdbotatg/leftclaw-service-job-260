// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/ContentRanking.sol";

/**
 * @notice Deploy script for the ContentRanking contract.
 * @dev Inherits ScaffoldETHDeploy which:
 *      - Includes forge-std/Script.sol for deployment
 *      - Includes ScaffoldEthDeployerRunner modifier
 *      - Provides `deployer` variable
 *
 * The contract owner is set to the client wallet directly in the constructor, so this
 * script does NOT call transferOwnership().
 *
 * Example:
 * yarn deploy --file DeployContentRanking.s.sol  # local anvil chain
 * yarn deploy --file DeployContentRanking.s.sol --network base # live network (requires keystore)
 */
contract DeployContentRanking is ScaffoldETHDeploy {
    /// @notice Client wallet that will own the deployed contract.
    address constant CLIENT_OWNER = 0x1d266aae9E1f8cb9228821C40fB5DbC7C771cbce;

    /// @notice CLAWD token is not yet deployed; the owner can set it later via setClawdToken().
    address constant CLAWD_TOKEN = address(0);

    function run() external ScaffoldEthDeployerRunner {
        ContentRanking contentRanking = new ContentRanking(CLAWD_TOKEN, CLIENT_OWNER);
        deployments.push(Deployment({ name: "ContentRanking", addr: address(contentRanking) }));
    }
}
