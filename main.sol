// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Basispointa
/// @notice Meridian lattice — rolling yield observation desk for lane-level basis-point telemetry.
/// @dev Codename: apricot drift / quiet compounding ledger. Deploy with zero constructor args.

library BpaMath {
    uint256 internal constant BPS_DENOM = 10_000;

    function minU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function maxU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clampU(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DENOM;
    }

    function addBps(uint256 baseBps, int256 deltaBps) internal pure returns (uint256) {
        if (deltaBps >= 0) {
            return baseBps + uint256(deltaBps);
        }
        uint256 drop = uint256(-deltaBps);
        return baseBps > drop ? baseBps - drop : 0;
    }

    function weightedMean(uint256 sumWeighted, uint256 sumWeights) internal pure returns (uint256) {
        if (sumWeights == 0) return 0;
        return sumWeighted / sumWeights;
    }

    function rollingIndex(uint256 head, uint256 cap, uint256 step) internal pure returns (uint256) {
        return (head + step) % cap;
    }

    function isSortedAsc(uint256[5] memory vals) internal pure returns (bool) {
        for (uint256 i = 1; i < 5; ++i) {
            if (vals[i - 1] > vals[i]) return false;
        }
        return true;
    }
}

library BpaPack {
  function packLaneKey(address asset, bytes32 tag) internal pure returns (bytes32) {
        return keccak256(abi.encode(asset, tag));
    }

    function laneDigestPartA(
        address asset,
        bytes32 tag,
        uint256 laneId,
        uint256 feeBps,
        bool openFlag
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(asset, tag, laneId, feeBps, openFlag));
    }

    function laneDigestPartB(
        uint256 minObs,
        uint256 maxObs,
        uint256 createdAt,
        address reporterHint
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(minObs, maxObs, createdAt, reporterHint));
    }

    function combineDigest(bytes32 hA, bytes32 hB) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hA, hB));
    }
}

contract Basispointa {
    using BpaMath for uint256;

    uint256 public constant PROTOCOL_VERSION = 5055;
    uint256 public constant SEED_YIELD_BPS = 723;
    uint256 public constant LANE_CAP = 274;
    uint256 public constant EPOCH_BLOCK_SPAN = 31835;
    uint256 public constant ROLLING_WINDOW = 62;
    uint256 public constant OBS_RING_CAP = 128;
    uint256 public constant USER_POSITION_CAP = 96;
    uint256 public constant USER_THRESHOLD_CAP = 24;
    uint256 public constant SCOUT_TABLE_CAP = 48;

    address public curator;
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    address public pendingCurator;
    bool public gridFrozen;

    uint256 public laneCount;
    uint256 public globalEpoch;
    uint256 public observationSeq;
    uint256 public positionSeq;
    uint256 public thresholdSeq;

    mapping(address => bool) public scoutTable;
    uint256 public scoutCount;
    mapping(uint256 => LaneSheet) public lanes;
    mapping(uint256 => ObservationRing) internal obsRings;
    mapping(uint256 => mapping(uint256 => EpochLaneSnap)) public epochSnaps;
    mapping(address => mapping(uint256 => UserPosition)) public positions;
    mapping(address => uint256) public positionCountByUser;
    mapping(address => mapping(uint256 => YieldThreshold)) public thresholds;
    mapping(address => uint256) public thresholdCountByUser;
    mapping(bytes32 => uint256) public laneKeyToId;
    mapping(uint256 => uint256) public laneBestBps;
    mapping(uint256 => uint256) public laneWorstBps;
    mapping(uint256 => uint256) public laneLastBps;
    mapping(uint256 => uint256) public laneObsCount;

    struct LaneSheet {
        address asset;
        bytes32 tag;
        address reporterHint;
        uint256 feeBps;
        uint256 minReportBps;
        uint256 maxReportBps;
        uint256 createdBlock;
