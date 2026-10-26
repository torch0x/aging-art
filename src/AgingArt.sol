// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title AgingArt
 * @notice Fully on-chain generative art that ages and gets covered in moss if neglected,
 *         but blooms with vibrant life when the owner interacts with it.
 */
contract AgingArt is ERC721 {
    using Strings for uint256;

    enum Stage {
        Blooming,
        Verdant,
        Mossy,
        Ancient
    }

    uint256 public nextTokenId;
    
    // Time thresholds
    uint256 public constant BLOOM_DURATION = 1 days;
    uint256 public constant VERDANT_DURATION = 3 days;
    uint256 public constant MOSSY_DURATION = 7 days;

    // Mapping from tokenId to last action timestamp
    mapping(uint256 => uint256) public lastActionTimestamp;

    event Cared(uint256 indexed tokenId, address indexed owner, uint256 timestamp);
    event Minted(uint256 indexed tokenId, address indexed recipient);

    constructor() ERC721("Aging Art", "AGEART") {}

    /**
     * @notice Mint a new Aging Art token.
     */
    function mint() external returns (uint256) {
        uint256 tokenId = ++nextTokenId;
        lastActionTimestamp[tokenId] = block.timestamp;
        emit Minted(tokenId, msg.sender);
        _safeMint(msg.sender, tokenId);
        return tokenId;
    }

    /**
     * @notice Nurture the art to bring it back to full bloom.
     * @param tokenId The ID of the token.
     */
    function care(uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(
            msg.sender == owner || isApprovedForAll(owner, msg.sender) || getApproved(tokenId) == msg.sender,
            "Not authorized"
        );
        lastActionTimestamp[tokenId] = block.timestamp;
        emit Cared(tokenId, msg.sender, block.timestamp);
    }

    /**
     * @notice Automatically resets age upon transfer to give the new owner a fresh start.
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            lastActionTimestamp[tokenId] = block.timestamp;
        }
        return from;
    }

    /**
     * @notice Returns elapsed time since last activity in seconds.
     */
    function getInactivityDuration(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        return block.timestamp - lastActionTimestamp[tokenId];
    }

    /**
     * @notice Returns current visual stage based on elapsed inactivity.
     */
    function getStage(uint256 tokenId) public view returns (Stage) {
        uint256 elapsed = getInactivityDuration(tokenId);
        if (elapsed < BLOOM_DURATION) {
            return Stage.Blooming;
        } else if (elapsed < VERDANT_DURATION) {
            return Stage.Verdant;
        } else if (elapsed < MOSSY_DURATION) {
            return Stage.Mossy;
        } else {
            return Stage.Ancient;
        }
    }

    /**
     * @notice Returns health/vitality percentage (0 - 100).
     */
    function getVitality(uint256 tokenId) public view returns (uint256) {
        uint256 elapsed = getInactivityDuration(tokenId);
        if (elapsed >= MOSSY_DURATION) return 0;
        return ((MOSSY_DURATION - elapsed) * 100) / MOSSY_DURATION;
    }

    function getStageName(Stage stage) public pure returns (string memory) {
        if (stage == Stage.Blooming) return "Blooming";
        if (stage == Stage.Verdant) return "Verdant";
        if (stage == Stage.Mossy) return "Mossy";
        return "Ancient Moss";
    }

    /**
     * @notice Generate pure on-chain SVG graphic for a given token.
     */
    function renderSVG(uint256 tokenId) public view returns (string memory) {
        Stage stage = getStage(tokenId);
        uint256 vitality = getVitality(tokenId);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" width="100%" height="100%">',
            _renderDefs(),
            _renderBackground(stage),
            _renderArtwork(stage),
            _renderUI(tokenId, stage, vitality),
            '</svg>'
        );
    }

    /**
     * @notice Generates standard ERC721 data URI metadata.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Stage stage = getStage(tokenId);
        uint256 vitality = getVitality(tokenId);
        uint256 inactivityHours = getInactivityDuration(tokenId) / 1 hours;
        string memory stageStr = getStageName(stage);

        string memory svg = renderSVG(tokenId);
        string memory imageUri = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        string memory json = string.concat(
            '{"name":"Aging Art #',
            tokenId.toString(),
            '","description":"Fully on-chain living art that reacts to owner activity. Left alone, it slowly gets covered in moss. Cared for, it blooms with vibrant life.",',
            '"image":"',
            imageUri,
            '",',
            '"attributes":[',
            '{"trait_type":"Stage","value":"',
            stageStr,
            '"},',
            '{"trait_type":"Vitality","value":',
            vitality.toString(),
            ',',
            '"max_value":100,"display_type":"boost_percentage"},',
            '{"trait_type":"Inactivity Hours","value":',
            inactivityHours.toString(),
            '}]}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _renderDefs() private pure returns (string memory) {
        return string.concat(
            '<defs>',
            '<radialGradient id="bloomGlow" cx="50%" cy="40%" r="55%"><stop offset="0%" stop-color="#ff70a6" stop-opacity="0.35"/><stop offset="100%" stop-color="#090d16" stop-opacity="0"/></radialGradient>',
            '<radialGradient id="mossGlow" cx="50%" cy="50%" r="60%"><stop offset="0%" stop-color="#2d4a22" stop-opacity="0.4"/><stop offset="100%" stop-color="#090d16" stop-opacity="0"/></radialGradient>',
            '<linearGradient id="trunkGrad" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#3e2723"/><stop offset="100%" stop-color="#1b120c"/></linearGradient>',
            '<linearGradient id="mossTrunk" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#384924"/><stop offset="100%" stop-color="#141f10"/></linearGradient>',
            '</defs>'
        );
    }

    function _renderBackground(Stage stage) private pure returns (string memory) {
        string memory glow = (stage == Stage.Blooming || stage == Stage.Verdant)
            ? '<rect width="500" height="500" fill="url(#bloomGlow)"/>'
            : '<rect width="500" height="500" fill="url(#mossGlow)"/>';

        return string.concat(
            '<rect width="500" height="500" fill="#0b0f19"/>',
            glow,
            '<rect x="20" y="20" width="460" height="460" fill="none" stroke="#ffffff" stroke-opacity="0.08" stroke-width="1"/>'
        );
    }

    function _renderArtwork(Stage stage) private pure returns (string memory) {
        // Base Tree / Monolith
        string memory trunkFill = (stage == Stage.Mossy || stage == Stage.Ancient) ? "url(#mossTrunk)" : "url(#trunkGrad)";
        string memory trunk = string.concat(
            '<path d="M240 380 Q235 280 210 220 Q190 175 160 145 M210 220 Q250 170 310 130 M250 240 Q280 190 340 180 M240 380 Q255 285 270 230" stroke="',
            trunkFill,
            '" stroke-width="12" stroke-linecap="round" fill="none"/>'
        );

        if (stage == Stage.Blooming) {
            return string.concat(
                trunk,
                // Blooming pink and gold flora
                '<g fill="#ff70a6" opacity="0.9">',
                '<circle cx="150" cy="140" r="14"/><circle cx="315" cy="125" r="16"/><circle cx="345" cy="175" r="13"/>',
                '<circle cx="210" cy="110" r="11"/><circle cx="270" cy="150" r="12"/><circle cx="180" cy="180" r="10"/>',
                '</g>',
                '<g fill="#ffd166">',
                '<circle cx="150" cy="140" r="6"/><circle cx="315" cy="125" r="7"/><circle cx="345" cy="175" r="5"/>',
                '<circle cx="210" cy="110" r="4"/><circle cx="270" cy="150" r="5"/><circle cx="180" cy="180" r="4"/>',
                '</g>',
                // Floating pollen/spores
                '<g fill="#06d6a0" opacity="0.8">',
                '<circle cx="130" cy="100" r="3"/><circle cx="360" cy="110" r="2.5"/><circle cx="230" cy="80" r="3"/>',
                '<circle cx="380" cy="210" r="2"/><circle cx="120" cy="200" r="2.5"/>',
                '</g>'
            );
        } else if (stage == Stage.Verdant) {
            return string.concat(
                trunk,
                // Healthy emerald foliage
                '<g fill="#2ec4b6" opacity="0.85">',
                '<circle cx="155" cy="142" r="14"/><circle cx="312" cy="128" r="15"/><circle cx="342" cy="178" r="12"/>',
                '<circle cx="212" cy="112" r="10"/><circle cx="268" cy="152" r="11"/><circle cx="182" cy="182" r="9"/>',
                '</g>',
                '<g fill="#57cc99" opacity="0.9">',
                '<circle cx="155" cy="142" r="8"/><circle cx="312" cy="128" r="9"/><circle cx="342" cy="178" r="7"/>',
                '</g>'
            );
        } else if (stage == Stage.Mossy) {
            return string.concat(
                trunk,
                // Creeping moss spots on branches and ground
                '<g fill="#556b2f" opacity="0.85">',
                '<ellipse cx="235" cy="270" rx="14" ry="8"/><ellipse cx="215" cy="225" rx="12" ry="7"/>',
                '<ellipse cx="265" cy="235" rx="15" ry="9"/><ellipse cx="165" cy="150" rx="10" ry="6"/>',
                '<ellipse cx="305" cy="135" rx="11" ry="6"/><ellipse cx="245" cy="360" rx="28" ry="10"/>',
                '</g>',
                '<g fill="#6b8e23" opacity="0.7">',
                '<circle cx="230" cy="265" r="5"/><circle cx="268" cy="232" r="6"/><circle cx="240" cy="358" r="12"/>',
                '</g>'
            );
        } else {
            // Ancient Moss - Heavy overgrown tendrils and dark lichen
            return string.concat(
                trunk,
                '<g fill="#283618" opacity="0.92">',
                '<ellipse cx="235" cy="270" rx="22" ry="12"/><ellipse cx="215" cy="225" rx="20" ry="11"/>',
                '<ellipse cx="265" cy="235" rx="24" ry="13"/><ellipse cx="165" cy="150" rx="18" ry="10"/>',
                '<ellipse cx="305" cy="135" rx="19" ry="10"/><ellipse cx="245" cy="365" rx="50" ry="16"/>',
                '</g>',
                '<g fill="#384924" opacity="0.85">',
                '<path d="M210 230 Q205 280 200 310" stroke="#384924" stroke-width="4" stroke-linecap="round"/>',
                '<path d="M260 240 Q265 295 270 330" stroke="#384924" stroke-width="5" stroke-linecap="round"/>',
                '<path d="M165 155 Q162 195 160 215" stroke="#384924" stroke-width="3" stroke-linecap="round"/>',
                '<circle cx="235" cy="270" r="8"/><circle cx="265" cy="235" r="9"/>',
                '</g>'
            );
        }
    }

    function _renderUI(uint256 tokenId, Stage stage, uint256 vitality) private pure returns (string memory) {
        string memory stageColor;
        string memory badgeText;

        if (stage == Stage.Blooming) {
            stageColor = "#ff70a6";
            badgeText = "BLOOMING";
        } else if (stage == Stage.Verdant) {
            stageColor = "#2ec4b6";
            badgeText = "VERDANT";
        } else if (stage == Stage.Mossy) {
            stageColor = "#8cb369";
            badgeText = "MOSSY";
        } else {
            stageColor = "#588157";
            badgeText = "ANCIENT MOSS";
        }

        uint256 barWidth = (vitality * 420) / 100;

        return string.concat(
            // Header text
            '<text x="40" y="55" font-family="monospace" font-size="16" font-weight="bold" fill="#ffffff" letter-spacing="2">AGING ART #',
            tokenId.toString(),
            '</text>',
            // Stage badge
            '<rect x="330" y="38" width="130" height="24" rx="4" fill="',
            stageColor,
            '" fill-opacity="0.15" stroke="',
            stageColor,
            '" stroke-width="1"/>',
            '<text x="395" y="54" font-family="monospace" font-size="11" font-weight="bold" fill="',
            stageColor,
            '" text-anchor="middle" letter-spacing="1">',
            badgeText,
            '</text>',
            // Vitality Progress Bar
            '<rect x="40" y="445" width="420" height="6" rx="3" fill="#ffffff" fill-opacity="0.1"/>',
            '<rect x="40" y="445" width="',
            barWidth.toString(),
            '" height="6" rx="3" fill="',
            stageColor,
            '"/>',
            '<text x="40" y="435" font-family="monospace" font-size="10" fill="#888888" letter-spacing="1">VITALITY: ',
            vitality.toString(),
            '%</text>'
        );
    }
}

