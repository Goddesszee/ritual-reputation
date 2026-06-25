// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SovereignRepAgent.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("Deploying SovereignRepAgent to Ritual Chain...");
        console.log("Deployer:", deployer);
        console.log("Balance: ", deployer.balance);

        vm.startBroadcast(deployerKey);

        SovereignRepAgent agent = new SovereignRepAgent();

        // Fund the agent's RitualWallet so it can pay for scheduling + LLM calls
        // Send 0.01 RITUAL to get it started
        (bool ok,) = address(agent).call{value: 0.01 ether}("");
        require(ok, "Fund failed");

        // Start the sovereign agent loop
        agent.startAgent();

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("SovereignRepAgent deployed:", address(agent));
        console.log("Agent is RUNNING — it will wake every 500 blocks");
        console.log("Explorer:", string(abi.encodePacked(
            "https://explorer.ritualfoundation.org/address/",
            vm.toString(address(agent))
        )));
        console.log("==========================================");
        console.log("Next: update CONTRACT_ADDRESS in index.html");
    }
}
