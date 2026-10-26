// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {AgingArt} from "../src/AgingArt.sol";

contract ExportSVGScript is Script {
    function run() external {
        address user = makeAddr("artOwner");
        AgingArt art = new AgingArt();

        vm.prank(user);
        uint256 tokenId = art.mint();

        // 1. Stage 0: Blooming (< 1 day)
        string memory svg0 = art.renderSVG(tokenId);
        vm.writeFile("svg/stage0_bloom.svg", svg0);

        // 2. Stage 1: Verdant (1-3 days)
        vm.warp(block.timestamp + 1.5 days);
        string memory svg1 = art.renderSVG(tokenId);
        vm.writeFile("svg/stage1_verdant.svg", svg1);

        // 3. Stage 2: Mossy (3-7 days)
        vm.warp(block.timestamp + 2.5 days); // total 4 days
        string memory svg2 = art.renderSVG(tokenId);
        vm.writeFile("svg/stage2_mossy.svg", svg2);

        // 4. Stage 3: Ancient Moss (>= 7 days)
        vm.warp(block.timestamp + 4 days); // total 8 days
        string memory svg3 = art.renderSVG(tokenId);
        vm.writeFile("svg/stage3_ancient.svg", svg3);
    }
}
