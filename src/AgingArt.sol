// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title AgingArt
 * @notice Fully on-chain generative art that ages and gets covered in moss if neglected,
 *         but blooms with vibrant life when the owner interacts with it.
 *
 * Each token has a deterministic `seed` set at mint, which controls the unique tree geometry
 * and colour palette. The seed is computed as
 * `keccak256(abi.encode(tokenId, msg.sender, blockhash(block.number - 1), block.chainid))`.
 *
 * @dev The seed is NOT attack-resistant randomness — it is only used to give each token a
 * unique visual appearance, not for lottery or financial outcomes. On some L2 chains
 * `blockhash` may provide limited entropy; this is acceptable for art uniqueness.
 *
 * The per-wallet mint limit (`MAX_PER_WALLET`) counts the number of times an address has
 * called `mint()`, NOT its current `balanceOf`. This prevents the limit from being bypassed
 * by transferring tokens away. However, it does NOT protect against sybil wallets — the real
 * hard cap is `MAX_SUPPLY`.
 *
 * `lastActionTimestamp` serves as the *age anchor*: `elapsed = block.timestamp - lastActionTimestamp`.
 * `care()` moves the token up exactly one stage (see {care}).
 */
contract AgingArt is ERC721 {
    using Strings for uint256;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum Stage {
        Blooming,
        Verdant,
        Mossy,
        Ancient
    }

    /**
     * @dev Packed tree geometry derived from a token's seed. Computed once and passed to
     *      render helpers to avoid stack-too-deep and redundant hashing.
     */
    struct TreeParams {
        // Trunk
        uint256 trunkLean; // 0-40 range, centred at 20 => actual lean = trunkLean - 20
        // Branches: 3-5 branches. Each branch has (endX, endY).
        uint256 branchCount; // 3..5
        uint256[5] branchEndX;
        uint256[5] branchEndY;
        // Palette index (0..NUM_PALETTES-1)
        uint256 paletteIdx;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Time thresholds for stage transitions.
    uint256 public constant BLOOM_DURATION = 1 days;
    uint256 public constant VERDANT_DURATION = 3 days;
    uint256 public constant MOSSY_DURATION = 7 days;

    /// @notice Minimum interval between successive `care()` calls on the same token.
    uint256 public constant CARE_COOLDOWN = 12 hours;

    uint256 private constant NUM_PALETTES = 6;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice Hard cap on total token supply (no burn, so totalSupply == nextTokenId).
    uint256 public immutable MAX_SUPPLY;

    /// @notice Maximum number of mints per wallet address.
    uint256 public immutable MAX_PER_WALLET;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 public nextTokenId;

    /**
     * @notice Age anchor for the token. `elapsed = block.timestamp - lastActionTimestamp[tokenId]`.
     *         Updated by `mint()` and `care()`. NOT reset on transfer.
     */
    mapping(uint256 => uint256) public lastActionTimestamp;

    /// @notice Timestamp of the most recent `care()` call for cooldown tracking.
    mapping(uint256 => uint256) public lastCareTimestamp;

    /// @notice Number of tokens minted by each address (never decremented).
    mapping(address => uint256) public mintedBy;

    /// @notice Deterministic visual seed, set once at mint and never changed.
    mapping(uint256 => uint256) private _seeds;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error MaxSupplyReached();
    error WalletMintLimitReached(address minter);
    error CareOnCooldown(uint256 tokenId, uint256 availableAt);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Cared(uint256 indexed tokenId, address indexed caller, Stage fromStage, Stage toStage, uint256 timestamp);
    event Minted(uint256 indexed tokenId, address indexed recipient);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param maxSupply_ Hard cap on total mints. Must be > 0.
     * @param maxPerWallet_ Per-wallet mint limit. Must be > 0.
     */
    constructor(uint256 maxSupply_, uint256 maxPerWallet_) ERC721("Aging Art", "AGEART") {
        require(maxSupply_ > 0, "maxSupply must be > 0");
        require(maxPerWallet_ > 0, "maxPerWallet must be > 0");
        MAX_SUPPLY = maxSupply_;
        MAX_PER_WALLET = maxPerWallet_;
    }

    // -------------------------------------------------------------------------
    // Mint
    // -------------------------------------------------------------------------

    /**
     * @notice Mint a new Aging Art token (free).
     * @dev All checks and state mutations happen BEFORE `_safeMint` to prevent reentrancy
     *      from bypassing supply/wallet limits via the `onERC721Received` callback.
     */
    function mint() external returns (uint256) {
        // --- checks ---
        uint256 tokenId = nextTokenId + 1;
        if (tokenId > MAX_SUPPLY) revert MaxSupplyReached();
        if (mintedBy[msg.sender] >= MAX_PER_WALLET) revert WalletMintLimitReached(msg.sender);

        // --- effects (before external call) ---
        nextTokenId = tokenId;
        mintedBy[msg.sender] += 1;
        lastActionTimestamp[tokenId] = block.timestamp;
        lastCareTimestamp[tokenId] = block.timestamp;
        _seeds[tokenId] =
            uint256(keccak256(abi.encode(tokenId, msg.sender, blockhash(block.number - 1), block.chainid)));

        // --- interaction ---
        _safeMint(msg.sender, tokenId);

        emit Minted(tokenId, msg.sender);
        return tokenId;
    }

    // -------------------------------------------------------------------------
    // Care
    // -------------------------------------------------------------------------

    /**
     * @notice Nurture the art to raise it by exactly one stage.
     *
     * Stage transitions on care:
     * - Blooming → Blooming (refresh; anchor reset to now)
     * - Verdant  → Blooming (anchor reset to now, elapsed becomes 0)
     * - Mossy    → Verdant  (anchor set so that elapsed == BLOOM_DURATION)
     * - Ancient  → Mossy    (anchor set so that elapsed == VERDANT_DURATION)
     *
     * The new anchor is always >= the old anchor (invariant: anchor never moves backward).
     *
     * A per-token cooldown of {CARE_COOLDOWN} (12 hours) applies. Transfer does NOT reset the
     * cooldown.
     *
     * @param tokenId The ID of the token to care for.
     */
    function care(uint256 tokenId) external {
        // 1. Existence check (reverts ERC721NonexistentToken if not minted).
        address owner = ownerOf(tokenId);

        // 2. Authorization (owner / approved / operator).
        if (!_isAuthorized(owner, msg.sender, tokenId)) {
            revert IERC721Errors.ERC721InsufficientApproval(msg.sender, tokenId);
        }

        // 3. Cooldown.
        uint256 availableAt = lastCareTimestamp[tokenId] + CARE_COOLDOWN;
        if (block.timestamp < availableAt) {
            revert CareOnCooldown(tokenId, availableAt);
        }

        uint256 elapsed = block.timestamp - lastActionTimestamp[tokenId];
        Stage fromStage = _stageOf(elapsed);

        // Compute target elapsed for the next-better stage.
        uint256 targetElapsed;
        if (fromStage == Stage.Ancient) {
            targetElapsed = VERDANT_DURATION; // → Mossy
        } else if (fromStage == Stage.Mossy) {
            targetElapsed = BLOOM_DURATION; // → Verdant
        } else {
            targetElapsed = 0; // Verdant → Blooming, or Blooming refresh
        }

        uint256 newAnchor = block.timestamp - targetElapsed;
        // Invariant: anchor never moves backward.
        if (newAnchor < lastActionTimestamp[tokenId]) {
            newAnchor = lastActionTimestamp[tokenId];
        }
        lastActionTimestamp[tokenId] = newAnchor;
        lastCareTimestamp[tokenId] = block.timestamp;

        Stage toStage = _stageOf(block.timestamp - newAnchor);
        emit Cared(tokenId, msg.sender, fromStage, toStage, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Total number of minted tokens (no burn, equals nextTokenId).
    function totalSupply() external view returns (uint256) {
        return nextTokenId;
    }

    /// @notice Earliest timestamp at which `care()` can next be called for `tokenId`.
    function nextCareAt(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return lastCareTimestamp[tokenId] + CARE_COOLDOWN;
    }

    /// @notice Whether `care()` can be called right now for `tokenId`.
    function canCare(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return block.timestamp >= lastCareTimestamp[tokenId] + CARE_COOLDOWN;
    }

    /**
     * @notice Returns the deterministic visual seed for `tokenId`.
     * @dev Reverts if the token does not exist.
     */
    function seedOf(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _seeds[tokenId];
    }

    /// @notice Returns elapsed time since last activity in seconds.
    function getInactivityDuration(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        return block.timestamp - lastActionTimestamp[tokenId];
    }

    /// @notice Returns current visual stage based on elapsed inactivity.
    function getStage(uint256 tokenId) public view returns (Stage) {
        uint256 elapsed = getInactivityDuration(tokenId);
        return _stageOf(elapsed);
    }

    /**
     * @notice Returns health/vitality percentage (0–100) using ceiling division.
     *
     * Invariants:
     * - vitality <= 100
     * - vitality is non-increasing over time (without care)
     * - vitality == 0 if and only if stage is Ancient (elapsed >= MOSSY_DURATION)
     */
    function getVitality(uint256 tokenId) public view returns (uint256) {
        uint256 elapsed = getInactivityDuration(tokenId);
        return _vitalityOf(elapsed);
    }

    function getStageName(Stage stage) public pure returns (string memory) {
        if (stage == Stage.Blooming) return "Blooming";
        if (stage == Stage.Verdant) return "Verdant";
        if (stage == Stage.Mossy) return "Mossy";
        return "Ancient Moss";
    }

    // -------------------------------------------------------------------------
    // Token URI
    // -------------------------------------------------------------------------

    /// @notice Generates standard ERC721 data URI metadata.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        uint256 elapsed = block.timestamp - lastActionTimestamp[tokenId];
        Stage stage = _stageOf(elapsed);
        uint256 vitality = _vitalityOf(elapsed);
        uint256 inactivityDays = elapsed / 1 days;
        string memory stageStr = getStageName(stage);

        uint256 seed = _seeds[tokenId];
        TreeParams memory tp = _treeParams(seed);

        string memory svg = _renderSVGInternal(tokenId, stage, vitality, tp);
        string memory imageUri = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        string memory paletteName = _paletteName(tp.paletteIdx);
        string memory tokenName = string.concat("Aging Art #", tokenId.toString());

        string memory json = string.concat(
            '{"name":"',
            tokenName,
            '","description":"Fully on-chain living art that reacts to owner activity. Left alone, it slowly gets covered in moss. Cared for, it blooms with vibrant life.",',
            '"image":"',
            imageUri,
            '",',
            '"attributes":[',
            '{"trait_type":"Stage","value":"',
            stageStr,
            '"},',
            '{"trait_type":"Vitality","display_type":"number","value":',
            vitality.toString(),
            ',"max_value":100},',
            '{"trait_type":"Inactivity Days","display_type":"number","value":',
            inactivityDays.toString(),
            "},",
            '{"trait_type":"Palette","value":"',
            paletteName,
            '"}]}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // -------------------------------------------------------------------------
    // SVG rendering (public entry)
    // -------------------------------------------------------------------------

    /// @notice Generate pure on-chain SVG graphic for a given token.
    function renderSVG(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        uint256 elapsed = block.timestamp - lastActionTimestamp[tokenId];
        Stage stage = _stageOf(elapsed);
        uint256 vitality = _vitalityOf(elapsed);
        uint256 seed = _seeds[tokenId];
        TreeParams memory tp = _treeParams(seed);
        return _renderSVGInternal(tokenId, stage, vitality, tp);
    }

    // -------------------------------------------------------------------------
    // Internal: stage / vitality
    // -------------------------------------------------------------------------

    function _stageOf(uint256 elapsed) internal pure returns (Stage) {
        if (elapsed < BLOOM_DURATION) return Stage.Blooming;
        if (elapsed < VERDANT_DURATION) return Stage.Verdant;
        if (elapsed < MOSSY_DURATION) return Stage.Mossy;
        return Stage.Ancient;
    }

    /// @dev Ceiling division for vitality so that vitality == 0 iff elapsed >= MOSSY_DURATION.
    function _vitalityOf(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= MOSSY_DURATION) return 0;
        // ceilDiv((MOSSY_DURATION - elapsed) * 100, MOSSY_DURATION)
        uint256 numerator = (MOSSY_DURATION - elapsed) * 100;
        return (numerator + MOSSY_DURATION - 1) / MOSSY_DURATION;
    }

    // -------------------------------------------------------------------------
    // Internal: seed → TreeParams
    // -------------------------------------------------------------------------

    function _treeParams(uint256 seed) internal pure returns (TreeParams memory tp) {
        // Use non-overlapping bit ranges from the seed for each parameter.
        // seed bits 0..7   → paletteIdx
        // seed bits 8..15  → trunkLean (0..40)
        // seed bits 16..18 → branchCount (3..5)
        // seed bits 19..26 → branch 0 endX jitter
        // seed bits 27..34 → branch 0 endY jitter
        // seed bits 35..42 → branch 1 endX jitter
        // seed bits 43..50 → branch 1 endY jitter
        // seed bits 51..58 → branch 2 endX jitter
        // seed bits 59..66 → branch 2 endY jitter
        // seed bits 67..74 → branch 3 endX jitter
        // seed bits 75..82 → branch 3 endY jitter
        // seed bits 83..90 → branch 4 endX jitter
        // seed bits 91..98 → branch 4 endY jitter

        tp.paletteIdx = seed % NUM_PALETTES;
        tp.trunkLean = ((seed >> 8) % 41); // 0..40
        tp.branchCount = 3 + ((seed >> 16) % 3); // 3..5

        // Base branch endpoints (before jitter), designed to stay in [40..460] x [80..420]
        // These are 5 canonical branch-end positions around the tree crown
        uint256[5] memory baseX = [uint256(160), 310, 340, 210, 270];
        uint256[5] memory baseY = [uint256(145), 130, 180, 110, 150];

        uint256 bitOffset = 19;
        for (uint256 i = 0; i < 5; i++) {
            // X jitter: ±30 → range 0..60 centred at 30
            uint256 jx = (seed >> bitOffset) % 61;
            bitOffset += 8;
            // Y jitter: ±25 → range 0..50 centred at 25
            uint256 jy = (seed >> bitOffset) % 51;
            bitOffset += 8;

            // Apply jitter ensuring we stay in [40..460] x [80..420]
            uint256 rawX = baseX[i] + jx;
            if (rawX >= 30) {
                rawX -= 30;
            } else {
                rawX = 40;
            }
            if (rawX < 40) rawX = 40;
            if (rawX > 460) rawX = 460;

            uint256 rawY = baseY[i] + jy;
            if (rawY >= 25) {
                rawY -= 25;
            } else {
                rawY = 80;
            }
            if (rawY < 80) rawY = 80;
            if (rawY > 380) rawY = 380; // keep above vitality bar area

            tp.branchEndX[i] = rawX;
            tp.branchEndY[i] = rawY;
        }
    }

    // -------------------------------------------------------------------------
    // Internal: palette data
    // -------------------------------------------------------------------------

    function _paletteName(uint256 idx) internal pure returns (string memory) {
        if (idx == 0) return "Sakura";
        if (idx == 1) return "Coral";
        if (idx == 2) return "Lavender";
        if (idx == 3) return "Amber";
        if (idx == 4) return "Crimson";
        return "Arctic";
    }

    /// @dev Returns (petalColor, coreColor, sporeColor, foliageColor1, foliageColor2).
    function _paletteColors(uint256 idx)
        internal
        pure
        returns (string memory petal, string memory core, string memory spore, string memory fol1, string memory fol2)
    {
        if (idx == 0) {
            return ("#ff70a6", "#ffd166", "#06d6a0", "#2ec4b6", "#57cc99");
        } else if (idx == 1) {
            return ("#ff6b6b", "#feca57", "#48dbfb", "#1dd1a1", "#55efc4");
        } else if (idx == 2) {
            return ("#a29bfe", "#fd79a8", "#81ecec", "#00b894", "#55efc4");
        } else if (idx == 3) {
            return ("#fdcb6e", "#e17055", "#00cec9", "#00b894", "#6c5ce7");
        } else if (idx == 4) {
            return ("#e74c3c", "#f39c12", "#2ecc71", "#27ae60", "#1abc9c");
        } else {
            return ("#74b9ff", "#dfe6e9", "#a29bfe", "#00cec9", "#81ecec");
        }
    }

    // -------------------------------------------------------------------------
    // Internal: SVG assembly
    // -------------------------------------------------------------------------

    function _renderSVGInternal(uint256 tokenId, Stage stage, uint256 vitality, TreeParams memory tp)
        internal
        pure
        returns (string memory)
    {
        string memory tokenName = string.concat("Aging Art #", tokenId.toString());
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" width="500" height="500">',
            "<title>",
            tokenName,
            "</title>",
            _renderDefs(),
            _renderBackground(stage),
            _renderArtwork(stage, tp),
            _renderUI(tokenId, stage, vitality),
            "</svg>"
        );
    }

    function _renderDefs() private pure returns (string memory) {
        return string.concat(
            "<defs>",
            '<radialGradient id="bloomGlow" cx="50%" cy="40%" r="55%"><stop offset="0%" stop-color="#ff70a6" stop-opacity="0.35"/><stop offset="100%" stop-color="#090d16" stop-opacity="0"/></radialGradient>',
            '<radialGradient id="mossGlow" cx="50%" cy="50%" r="60%"><stop offset="0%" stop-color="#2d4a22" stop-opacity="0.4"/><stop offset="100%" stop-color="#090d16" stop-opacity="0"/></radialGradient>',
            '<linearGradient id="trunkGrad" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#3e2723"/><stop offset="100%" stop-color="#1b120c"/></linearGradient>',
            '<linearGradient id="mossTrunk" x1="0%" y1="0%" x2="0%" y2="100%"><stop offset="0%" stop-color="#384924"/><stop offset="100%" stop-color="#141f10"/></linearGradient>',
            "</defs>"
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

    // -------------------------------------------------------------------------
    // Internal: artwork rendering (tree + decorations)
    // -------------------------------------------------------------------------

    function _renderArtwork(Stage stage, TreeParams memory tp) private pure returns (string memory) {
        string memory trunk = _renderTrunk(stage, tp);

        if (stage == Stage.Blooming) {
            return string.concat(trunk, _renderBlooming(tp));
        } else if (stage == Stage.Verdant) {
            return string.concat(trunk, _renderVerdant(tp));
        } else if (stage == Stage.Mossy) {
            return string.concat(trunk, _renderMossy(tp));
        } else {
            return string.concat(trunk, _renderAncient(tp));
        }
    }

    function _renderTrunk(Stage stage, TreeParams memory tp) private pure returns (string memory) {
        string memory trunkFill =
            (stage == Stage.Mossy || stage == Stage.Ancient) ? "url(#mossTrunk)" : "url(#trunkGrad)";

        // Trunk base at (240 + lean adjustment, 380)
        // lean: tp.trunkLean 0..40 centred at 20 → shift = trunkLean - 20 → range [-20..+20]
        // To avoid signed math: baseX = 220 + trunkLean (range 220..260)
        uint256 baseX = 220 + tp.trunkLean;

        // Build the trunk path as connected segments from base to each branch end
        // Main trunk goes up to a midpoint, then branches fan out
        uint256 midX = baseX;
        uint256 midY = 240;

        string memory path =
            string.concat('<path d="M', baseX.toString(), " 380 Q", midX.toString(), " ", midY.toString());

        // Connect to first branch end for the main trunk curve
        if (tp.branchCount > 0) {
            path = string.concat(path, " ", tp.branchEndX[0].toString(), " ", tp.branchEndY[0].toString());
        }

        // Additional branch lines from trunk midpoint
        for (uint256 i = 1; i < tp.branchCount; i++) {
            path = string.concat(
                path,
                " M",
                midX.toString(),
                " ",
                midY.toString(),
                " Q",
                _midVal(midX, tp.branchEndX[i]).toString(),
                " ",
                _midVal(midY, tp.branchEndY[i]).toString(),
                " ",
                tp.branchEndX[i].toString(),
                " ",
                tp.branchEndY[i].toString()
            );
        }

        path = string.concat(path, '" stroke="', trunkFill, '" stroke-width="12" stroke-linecap="round" fill="none"/>');

        return path;
    }

    function _renderBlooming(TreeParams memory tp) private pure returns (string memory) {
        (string memory petal, string memory core, string memory spore,,) = _paletteColors(tp.paletteIdx);

        // Flowers at branch endpoints
        string memory petals = string.concat('<g fill="', petal, '" opacity="0.9">');
        string memory cores = string.concat('<g fill="', core, '">');

        for (uint256 i = 0; i < tp.branchCount; i++) {
            uint256 r = 11 + (i * 2); // petal radius 11..19
            uint256 cr = 4 + i; // core radius 4..8
            string memory cx = tp.branchEndX[i].toString();
            string memory cy = tp.branchEndY[i].toString();
            petals = string.concat(petals, '<circle cx="', cx, '" cy="', cy, '" r="', r.toString(), '"/>');
            cores = string.concat(cores, '<circle cx="', cx, '" cy="', cy, '" r="', cr.toString(), '"/>');
        }

        petals = string.concat(petals, "</g>");
        cores = string.concat(cores, "</g>");

        // Spores floating near branch tips
        string memory spores = string.concat('<g fill="', spore, '" opacity="0.8">');
        for (uint256 i = 0; i < tp.branchCount; i++) {
            // Offset spores slightly above and to the side
            uint256 sx = tp.branchEndX[i] > 60 ? tp.branchEndX[i] - 20 : 40;
            uint256 sy = tp.branchEndY[i] > 100 ? tp.branchEndY[i] - 20 : 80;
            if (sy < 80) sy = 80;
            spores = string.concat(spores, '<circle cx="', sx.toString(), '" cy="', sy.toString(), '" r="3"/>');
        }
        spores = string.concat(spores, "</g>");

        return string.concat(petals, cores, spores);
    }

    function _renderVerdant(TreeParams memory tp) private pure returns (string memory) {
        (,,, string memory fol1, string memory fol2) = _paletteColors(tp.paletteIdx);

        string memory outer = string.concat('<g fill="', fol1, '" opacity="0.85">');
        string memory inner = string.concat('<g fill="', fol2, '" opacity="0.9">');

        for (uint256 i = 0; i < tp.branchCount; i++) {
            uint256 r1 = 12 + (i % 3) * 2;
            uint256 r2 = 7 + (i % 3);
            string memory cx = tp.branchEndX[i].toString();
            string memory cy = tp.branchEndY[i].toString();
            outer = string.concat(outer, '<circle cx="', cx, '" cy="', cy, '" r="', r1.toString(), '"/>');
            inner = string.concat(inner, '<circle cx="', cx, '" cy="', cy, '" r="', r2.toString(), '"/>');
        }

        outer = string.concat(outer, "</g>");
        inner = string.concat(inner, "</g>");

        return string.concat(outer, inner);
    }

    function _renderMossy(TreeParams memory tp) private pure returns (string memory) {
        // Moss at branch ends and along branches (shared moss colours)
        string memory moss = '<g fill="#556b2f" opacity="0.85">';

        // Moss at each branch end
        for (uint256 i = 0; i < tp.branchCount; i++) {
            uint256 rx = 10 + (i * 2);
            uint256 ry = 6 + i;
            moss = string.concat(
                moss,
                '<ellipse cx="',
                tp.branchEndX[i].toString(),
                '" cy="',
                tp.branchEndY[i].toString(),
                '" rx="',
                rx.toString(),
                '" ry="',
                ry.toString(),
                '"/>'
            );
        }

        // Moss at trunk midpoint area
        uint256 baseX = 220 + tp.trunkLean;
        moss = string.concat(
            moss,
            '<ellipse cx="',
            baseX.toString(),
            '" cy="270" rx="14" ry="8"/>',
            '<ellipse cx="',
            baseX.toString(),
            '" cy="360" rx="28" ry="10"/>'
        );
        moss = string.concat(moss, "</g>");

        // Lighter moss highlights
        string memory highlights = '<g fill="#6b8e23" opacity="0.7">';
        highlights = string.concat(
            highlights,
            '<circle cx="',
            baseX.toString(),
            '" cy="265" r="5"/>',
            '<circle cx="',
            baseX.toString(),
            '" cy="358" r="12"/>'
        );
        highlights = string.concat(highlights, "</g>");

        return string.concat(moss, highlights);
    }

    function _renderAncient(TreeParams memory tp) private pure returns (string memory) {
        uint256 baseX = 220 + tp.trunkLean;

        // Heavy overgrown moss at branch ends
        string memory heavy = '<g fill="#283618" opacity="0.92">';
        for (uint256 i = 0; i < tp.branchCount; i++) {
            uint256 rx = 16 + (i * 3);
            uint256 ry = 9 + (i * 2);
            heavy = string.concat(
                heavy,
                '<ellipse cx="',
                tp.branchEndX[i].toString(),
                '" cy="',
                tp.branchEndY[i].toString(),
                '" rx="',
                rx.toString(),
                '" ry="',
                ry.toString(),
                '"/>'
            );
        }
        // Heavy ground moss
        heavy = string.concat(
            heavy,
            '<ellipse cx="',
            baseX.toString(),
            '" cy="270" rx="22" ry="12"/>',
            '<ellipse cx="',
            baseX.toString(),
            '" cy="365" rx="50" ry="16"/>'
        );
        heavy = string.concat(heavy, "</g>");

        // Dripping tendrils from branch ends
        string memory tendrils = '<g fill="#384924" opacity="0.85">';
        for (uint256 i = 0; i < tp.branchCount; i++) {
            uint256 ex = tp.branchEndX[i];
            uint256 ey = tp.branchEndY[i];
            uint256 tendrilEnd = ey + 50;
            if (tendrilEnd > 380) tendrilEnd = 380;
            tendrils = string.concat(
                tendrils,
                '<path d="M',
                ex.toString(),
                " ",
                ey.toString(),
                " Q",
                ex.toString(),
                " ",
                _midVal(ey, tendrilEnd).toString(),
                " ",
                ex.toString(),
                " ",
                tendrilEnd.toString(),
                '" stroke="#384924" stroke-width="4" stroke-linecap="round" fill="none"/>',
                '<circle cx="',
                ex.toString(),
                '" cy="',
                ey.toString(),
                '" r="8"/>'
            );
        }
        tendrils = string.concat(tendrils, "</g>");

        return string.concat(heavy, tendrils);
    }

    // -------------------------------------------------------------------------
    // Internal: UI overlay
    // -------------------------------------------------------------------------

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
            "</text>",
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
            "</text>",
            // Vitality Progress Bar
            '<rect x="40" y="445" width="420" height="6" rx="3" fill="#ffffff" fill-opacity="0.1"/>',
            '<rect x="40" y="445" width="',
            barWidth.toString(),
            '" height="6" rx="3" fill="',
            stageColor,
            '"/>',
            '<text x="40" y="435" font-family="monospace" font-size="10" fill="#888888" letter-spacing="1">VITALITY: ',
            vitality.toString(),
            "%</text>"
        );
    }

    // -------------------------------------------------------------------------
    // Internal: math helpers
    // -------------------------------------------------------------------------

    /// @dev Returns the midpoint of two uint256 values.
    function _midVal(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b) / 2;
    }
}
