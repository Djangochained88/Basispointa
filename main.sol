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
        uint256 obsHead;
        uint256 obsTail;
        uint256 obsFilled;
        uint256 rollingSum;
        uint256 rollingWeight;
        bool intakeOpen;
        bool archived;
    }

    struct ObservationRing {
        mapping(uint256 => ObsCell) cells;
    }

    struct ObsCell {
        uint256 bps;
        uint256 weight;
        uint256 blockNum;
        address scout;
        uint256 epochTag;
    }

    struct EpochLaneSnap {
        uint256 meanBps;
        uint256 peakBps;
        uint256 floorBps;
        uint256 sampleCount;
        uint256 sealedBlock;
        bool sealed;
    }

    struct UserPosition {
        uint256 laneId;
        uint256 principalUnits;
        uint256 entryBps;
        uint256 openedBlock;
        uint256 lastCheckBlock;
        bool closed;
    }

    struct YieldThreshold {
        uint256 laneId;
        uint256 floorBps;
        uint256 ceilingBps;
        bool active;
        bytes32 labelHash;
    }

    error BPA_Frozen();
    error BPA_NotCurator(address caller);
    error BPA_NotScout(address caller);
    error BPA_ZeroAddress();
    error BPA_ZeroAmount();
    error BPA_LaneCap();
    error BPA_LaneMissing(uint256 laneId);
    error BPA_LaneClosed(uint256 laneId);
    error BPA_LaneArchived(uint256 laneId);
    error BPA_DuplicateLane(bytes32 laneKey);
    error BPA_BpsOutOfBand(uint256 bps, uint256 lo, uint256 hi);
    error BPA_WeightZero();
    error BPA_PositionCap();
    error BPA_PositionMissing(uint256 positionId);
    error BPA_PositionClosed(uint256 positionId);
    error BPA_NotPositionOwner(address caller, uint256 positionId);
    error BPA_ThresholdCap();
    error BPA_ThresholdMissing(uint256 thresholdId);
    error BPA_ScoutCap();
    error BPA_ScoutExists(address scout);
    error BPA_ScoutAbsent(address scout);
    error BPA_BadEpoch(uint256 epoch);
    error BPA_SnapAlreadySealed(uint256 epoch, uint256 laneId);
    error BPA_SnapNotSealed(uint256 epoch, uint256 laneId);
    error BPA_RangeInverted(uint256 floorBps, uint256 ceilingBps);
    error BPA_NoPendingCurator();
    error BPA_PendingMismatch(address expected, address got);

    event Opened(uint256 indexed laneId, address indexed asset, bytes32 indexed tag, uint256 feeBps);
    event Tuned(uint256 indexed laneId, uint256 minReportBps, uint256 maxReportBps, bool intakeOpen);
    event Archived(uint256 indexed laneId, address indexed curator);
    event ScoutAdded(address indexed scout, address indexed curator);
    event ScoutRemoved(address indexed scout, address indexed curator);
    event Posted(
        uint256 indexed laneId,
        uint256 indexed obsId,
        uint256 bps,
        uint256 weight,
        address indexed scout,
        uint256 epochTag
    );
    event Rolled(uint256 indexed laneId, uint256 meanBps, uint256 obsFilled);
    event Sealed(uint256 indexed epoch, uint256 indexed laneId, uint256 meanBps, uint256 peakBps, uint256 floorBps);
    event PositionOpened(
        address indexed user,
        uint256 indexed positionId,
        uint256 indexed laneId,
        uint256 principalUnits,
        uint256 entryBps
    );
    event PositionChecked(address indexed user, uint256 indexed positionId, uint256 currentBps, bool withinBand);
    event PositionClosed(address indexed user, uint256 indexed positionId, uint256 exitBps);
    event ThresholdSet(
        address indexed user,
        uint256 indexed thresholdId,
        uint256 indexed laneId,
        uint256 floorBps,
        uint256 ceilingBps
    );
    event ThresholdToggled(address indexed user, uint256 indexed thresholdId, bool active);
    event CuratorProposed(address indexed currentCurator, address indexed nominee);
    event CuratorAccepted(address indexed previousCurator, address indexed newCurator);
    event GridFreezeSet(bool frozen, address indexed curator);
    event EpochAdvanced(uint256 indexed newEpoch, uint256 atBlock);

    modifier whenUnfrozen() {
        if (gridFrozen) revert BPA_Frozen();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert BPA_NotCurator(msg.sender);
        _;
    }

    modifier onlyScout() {
        if (!scoutTable[msg.sender] && msg.sender != curator) revert BPA_NotScout(msg.sender);
        _;
    }

    constructor() {
        curator = msg.sender;
        ADDRESS_A = 0xB8F1A8273c264314053706f2Fe1f8517d1FB4012;
        ADDRESS_B = 0xaaF1AF06318Bdd0225856536032f4Dd4D9002fc2;
        ADDRESS_C = 0x47FdA50E1FDb7ca47dC701a4c9383fcB3529B6Ca;
        globalEpoch = 1;
    }

    // --- curator controls ---

    function proposeCurator(address nominee) external onlyCurator whenUnfrozen {
        if (nominee == address(0)) revert BPA_ZeroAddress();
        pendingCurator = nominee;
        emit CuratorProposed(curator, nominee);
    }

    function acceptCurator() external whenUnfrozen {
        if (pendingCurator == address(0)) revert BPA_NoPendingCurator();
        if (msg.sender != pendingCurator) revert BPA_PendingMismatch(pendingCurator, msg.sender);
        address previous = curator;
        curator = msg.sender;
        pendingCurator = address(0);
        emit CuratorAccepted(previous, msg.sender);
    }

    function setGridFrozen(bool frozen) external onlyCurator {
        gridFrozen = frozen;
        emit GridFreezeSet(frozen, msg.sender);
    }

    function addScout(address scout) external onlyCurator whenUnfrozen {
        if (scout == address(0)) revert BPA_ZeroAddress();
        if (scoutTable[scout]) revert BPA_ScoutExists(scout);
        if (scoutCount >= SCOUT_TABLE_CAP) revert BPA_ScoutCap();
        scoutTable[scout] = true;
        unchecked { scoutCount += 1; }
        emit ScoutAdded(scout, msg.sender);
    }

    function removeScout(address scout) external onlyCurator whenUnfrozen {
        if (!scoutTable[scout]) revert BPA_ScoutAbsent(scout);
        scoutTable[scout] = false;
        unchecked { scoutCount -= 1; }
        emit ScoutRemoved(scout, msg.sender);
    }

    function advanceEpoch() external onlyCurator whenUnfrozen {
        unchecked {
            globalEpoch += 1;
        }
        emit EpochAdvanced(globalEpoch, block.number);
    }

    // --- lane lifecycle ---

    function openLane(
        address asset,
        bytes32 tag,
        address reporterHint,
        uint256 feeBps,
        uint256 minReportBps,
        uint256 maxReportBps
    ) external onlyCurator whenUnfrozen returns (uint256 laneId) {
        if (asset == address(0)) revert BPA_ZeroAddress();
        if (laneCount >= LANE_CAP) revert BPA_LaneCap();
        if (minReportBps > maxReportBps) revert BPA_RangeInverted(minReportBps, maxReportBps);
        bytes32 key = BpaPack.packLaneKey(asset, tag);
        if (laneKeyToId[key] != 0) revert BPA_DuplicateLane(key);

        unchecked {
            laneCount += 1;
            laneId = laneCount;
        }

        LaneSheet storage lane = lanes[laneId];
        lane.asset = asset;
        lane.tag = tag;
        lane.reporterHint = reporterHint;
        lane.feeBps = feeBps;
        lane.minReportBps = minReportBps;
        lane.maxReportBps = maxReportBps;
        lane.createdBlock = block.number;
        lane.intakeOpen = true;

        laneKeyToId[key] = laneId;
        laneBestBps[laneId] = 0;
        laneWorstBps[laneId] = type(uint256).max;
        laneLastBps[laneId] = SEED_YIELD_BPS;

        emit Opened(laneId, asset, tag, feeBps);
    }

    function tuneLane(
        uint256 laneId,
        uint256 minReportBps,
        uint256 maxReportBps,
        bool intakeOpen
    ) external onlyCurator whenUnfrozen {
        LaneSheet storage lane = _requireLane(laneId);
        if (lane.archived) revert BPA_LaneArchived(laneId);
        if (minReportBps > maxReportBps) revert BPA_RangeInverted(minReportBps, maxReportBps);
        lane.minReportBps = minReportBps;
        lane.maxReportBps = maxReportBps;
        lane.intakeOpen = intakeOpen;
        emit Tuned(laneId, minReportBps, maxReportBps, intakeOpen);
    }

    function archiveLane(uint256 laneId) external onlyCurator whenUnfrozen {
        LaneSheet storage lane = _requireLane(laneId);
        lane.archived = true;
        lane.intakeOpen = false;
        emit Archived(laneId, msg.sender);
    }

    // --- observations ---

    function postObservation(uint256 laneId, uint256 bps, uint256 weight) external onlyScout whenUnfrozen {
        if (weight == 0) revert BPA_WeightZero();
        LaneSheet storage lane = _requireLane(laneId);
        if (lane.archived) revert BPA_LaneArchived(laneId);
        if (!lane.intakeOpen) revert BPA_LaneClosed(laneId);
        if (bps < lane.minReportBps || bps > lane.maxReportBps) {
            revert BPA_BpsOutOfBand(bps, lane.minReportBps, lane.maxReportBps);
        }

        ObservationRing storage ring = obsRings[laneId];
        if (lane.obsFilled >= ROLLING_WINDOW) {
            uint256 evictIdx = (lane.obsHead + OBS_RING_CAP - ROLLING_WINDOW) % OBS_RING_CAP;
            ObsCell storage evicted = ring.cells[evictIdx];
            lane.rollingSum -= evicted.bps * evicted.weight;
            lane.rollingWeight -= evicted.weight;
        }

        uint256 slot = lane.obsHead;
        ring.cells[slot] = ObsCell({
            bps: bps,
            weight: weight,
            blockNum: block.number,
            scout: msg.sender,
            epochTag: globalEpoch
        });

        unchecked {
            lane.obsHead = (lane.obsHead + 1) % OBS_RING_CAP;
            if (lane.obsFilled < OBS_RING_CAP) {
                lane.obsFilled += 1;
            } else {
                lane.obsTail = (lane.obsTail + 1) % OBS_RING_CAP;
            }
            lane.rollingSum += bps * weight;
            lane.rollingWeight += weight;
            observationSeq += 1;
            laneObsCount[laneId] += 1;
        }

        if (bps > laneBestBps[laneId]) laneBestBps[laneId] = bps;
        if (bps < laneWorstBps[laneId]) laneWorstBps[laneId] = bps;
        laneLastBps[laneId] = bps;

        emit Posted(laneId, observationSeq, bps, weight, msg.sender, globalEpoch);
        emit Rolled(laneId, rollingMeanBps(laneId), lane.obsFilled);
    }

    function sealEpochLane(uint256 epoch, uint256 laneId) external onlyCurator whenUnfrozen {
        if (epoch == 0 || epoch > globalEpoch) revert BPA_BadEpoch(epoch);
        _requireLane(laneId);
        EpochLaneSnap storage snap = epochSnaps[epoch][laneId];
        if (snap.sealed) revert BPA_SnapAlreadySealed(epoch, laneId);

        (uint256 meanBps, uint256 peakBps, uint256 floorBps, uint256 samples) = _epochStats(laneId, epoch);
        snap.meanBps = meanBps;
        snap.peakBps = peakBps;
        snap.floorBps = floorBps;
        snap.sampleCount = samples;
        snap.sealedBlock = block.number;
        snap.sealed = true;

        emit Sealed(epoch, laneId, meanBps, peakBps, floorBps);
    }

    // --- positions ---

    function openPosition(uint256 laneId, uint256 principalUnits, uint256 entryBps)
        external
        whenUnfrozen
        returns (uint256 positionId)
    {
        if (principalUnits == 0) revert BPA_ZeroAmount();
        LaneSheet storage lane = _requireLane(laneId);
        if (lane.archived) revert BPA_LaneArchived(laneId);
        if (entryBps < lane.minReportBps || entryBps > lane.maxReportBps) {
            revert BPA_BpsOutOfBand(entryBps, lane.minReportBps, lane.maxReportBps);
        }
        if (positionCountByUser[msg.sender] >= USER_POSITION_CAP) revert BPA_PositionCap();

        unchecked {
            positionSeq += 1;
            positionId = positionSeq;
            positionCountByUser[msg.sender] += 1;
        }

        positions[msg.sender][positionId] = UserPosition({
            laneId: laneId,
            principalUnits: principalUnits,
            entryBps: entryBps,
            openedBlock: block.number,
            lastCheckBlock: block.number,
            closed: false
        });

        emit PositionOpened(msg.sender, positionId, laneId, principalUnits, entryBps);
    }

    function checkPosition(uint256 positionId) external whenUnfrozen returns (bool withinBand) {
        UserPosition storage pos = _requireOpenPosition(msg.sender, positionId);
        uint256 current = laneLastBps[pos.laneId];
        withinBand = _withinLaneBand(pos.laneId, current);
        pos.lastCheckBlock = block.number;
        emit PositionChecked(msg.sender, positionId, current, withinBand);
    }

    function closePosition(uint256 positionId) external whenUnfrozen {
        UserPosition storage pos = _requireOpenPosition(msg.sender, positionId);
        pos.closed = true;
        uint256 exitBps = laneLastBps[pos.laneId];
        emit PositionClosed(msg.sender, positionId, exitBps);
    }

    // --- thresholds ---

    function setThreshold(
        uint256 laneId,
        uint256 floorBps,
        uint256 ceilingBps,
        bytes32 labelHash
    ) external whenUnfrozen returns (uint256 thresholdId) {
        _requireLane(laneId);
        if (floorBps > ceilingBps) revert BPA_RangeInverted(floorBps, ceilingBps);
        if (thresholdCountByUser[msg.sender] >= USER_THRESHOLD_CAP) revert BPA_ThresholdCap();

        unchecked {
            thresholdSeq += 1;
            thresholdId = thresholdSeq;
            thresholdCountByUser[msg.sender] += 1;
        }

        thresholds[msg.sender][thresholdId] = YieldThreshold({
            laneId: laneId,
            floorBps: floorBps,
            ceilingBps: ceilingBps,
            active: true,
            labelHash: labelHash
        });

        emit ThresholdSet(msg.sender, thresholdId, laneId, floorBps, ceilingBps);
    }

    function toggleThreshold(uint256 thresholdId, bool active) external whenUnfrozen {
        YieldThreshold storage th = thresholds[msg.sender][thresholdId];
        if (th.laneId == 0 && !active && th.floorBps == 0 && th.ceilingBps == 0) {
            revert BPA_ThresholdMissing(thresholdId);
        }
        th.active = active;
        emit ThresholdToggled(msg.sender, thresholdId, active);
    }

    function evaluateThreshold(uint256 thresholdId) external view returns (bool ok, uint256 currentBps) {
        YieldThreshold storage th = thresholds[msg.sender][thresholdId];
        if (th.laneId == 0 && th.floorBps == 0 && th.ceilingBps == 0) {
            revert BPA_ThresholdMissing(thresholdId);
        }
        currentBps = laneLastBps[th.laneId];
        ok = th.active && currentBps >= th.floorBps && currentBps <= th.ceilingBps;
    }

    // --- yield checker views ---

    function rollingMeanBps(uint256 laneId) public view returns (uint256) {
        LaneSheet storage lane = lanes[laneId];
        if (lane.asset == address(0)) revert BPA_LaneMissing(laneId);
        return BpaMath.weightedMean(lane.rollingSum, lane.rollingWeight);
    }

    function yieldSpreadBps(uint256 laneId) external view returns (uint256) {
        _requireLaneView(laneId);
        uint256 best = laneBestBps[laneId];
        uint256 worst = laneWorstBps[laneId];
        if (worst == type(uint256).max) return 0;
        return worst > best ? worst - best : best - worst;
    }

    function driftFromEntryBps(uint256 laneId, uint256 entryBps) external view returns (int256) {
        _requireLaneView(laneId);
        uint256 last = laneLastBps[laneId];
        if (last >= entryBps) return int256(last - entryBps);
        return -int256(entryBps - last);
    }

    function compareLanes(uint256 laneA, uint256 laneB) external view returns (int256 deltaBps) {
        _requireLaneView(laneA);
        _requireLaneView(laneB);
        uint256 a = laneLastBps[laneA];
        uint256 b = laneLastBps[laneB];
        if (a >= b) return int256(a - b);
        return -int256(b - a);
    }

    function laneHealthScore(uint256 laneId) public view returns (uint256 score) {
        _requireLaneView(laneId);
        return _laneHealthScoreInternal(laneId);
    }

    function laneDigest(uint256 laneId) external view returns (bytes32) {
        LaneSheet storage lane = _requireLaneView(laneId);
        bytes32 hA = BpaPack.laneDigestPartA(lane.asset, lane.tag, laneId, lane.feeBps, lane.intakeOpen);
        bytes32 hB = BpaPack.laneDigestPartB(
            lane.minReportBps,
            lane.maxReportBps,
            lane.createdBlock,
            lane.reporterHint
        );
        return BpaPack.combineDigest(hA, hB);
    }

    function anchorFingerprint() external view returns (bytes32) {
        bytes32 hA = keccak256(abi.encode(ADDRESS_A, ADDRESS_B));
        bytes32 hB = keccak256(abi.encode(ADDRESS_C, PROTOCOL_VERSION));
        return BpaPack.combineDigest(hA, hB);
    }

    function configSheet()
        external
        view
        returns (
            address curator_,
            address addressA_,
            address addressB_,
            address addressC_,
            bool gridFrozen_,
            uint256 epoch_,
            uint256 laneTotal_
        )
    {
        return (curator, ADDRESS_A, ADDRESS_B, ADDRESS_C, gridFrozen, globalEpoch, laneCount);
    }

    function laneSummary(uint256 laneId)
        external
        view
        returns (
            address asset,
            bytes32 tag,
            uint256 lastBps,
            uint256 meanBps,
            uint256 bestBps,
            uint256 worstBps,
            uint256 obsCount,
            bool intakeOpen,
            bool archived
        )
    {
        LaneSheet storage lane = _requireLaneView(laneId);
        asset = lane.asset;
        tag = lane.tag;
        lastBps = laneLastBps[laneId];
        meanBps = BpaMath.weightedMean(lane.rollingSum, lane.rollingWeight);
        bestBps = laneBestBps[laneId];
        worstBps = laneWorstBps[laneId];
        obsCount = laneObsCount[laneId];
        intakeOpen = lane.intakeOpen;
        archived = lane.archived;
    }

    function observationAt(uint256 laneId, uint256 ringIndex)
        external
        view
        returns (uint256 bps, uint256 weight, uint256 blockNum, address scout, uint256 epochTag)
    {
        LaneSheet storage lane = _requireLaneView(laneId);
        if (ringIndex >= lane.obsFilled) revert BPA_ZeroAmount();
        uint256 idx = (lane.obsTail + ringIndex) % OBS_RING_CAP;
        ObsCell storage cell = obsRings[laneId].cells[idx];
        return (cell.bps, cell.weight, cell.blockNum, cell.scout, cell.epochTag);
    }

    function positionView(address user, uint256 positionId)
        external
        view
        returns (
            uint256 laneId,
            uint256 principalUnits,
            uint256 entryBps,
            uint256 openedBlock,
            uint256 lastCheckBlock,
            bool closed,
            uint256 currentBps,
            int256 driftBps
        )
    {
        UserPosition storage pos = positions[user][positionId];
        if (pos.openedBlock == 0) revert BPA_PositionMissing(positionId);
        laneId = pos.laneId;
        principalUnits = pos.principalUnits;
        entryBps = pos.entryBps;
        openedBlock = pos.openedBlock;
        lastCheckBlock = pos.lastCheckBlock;
        closed = pos.closed;
        currentBps = laneLastBps[laneId];
        if (currentBps >= entryBps) driftBps = int256(currentBps - entryBps);
        else driftBps = -int256(entryBps - currentBps);
    }

    function epochSnapView(uint256 epoch, uint256 laneId)
        external
        view
        returns (uint256 meanBps, uint256 peakBps, uint256 floorBps, uint256 sampleCount, bool sealed)
    {
        EpochLaneSnap storage snap = epochSnaps[epoch][laneId];
        return (snap.meanBps, snap.peakBps, snap.floorBps, snap.sampleCount, snap.sealed);
    }

    // --- internals ---

    function _requireLane(uint256 laneId) internal view returns (LaneSheet storage lane) {
        lane = lanes[laneId];
        if (lane.asset == address(0)) revert BPA_LaneMissing(laneId);
    }

    function _requireLaneView(uint256 laneId) internal view returns (LaneSheet storage lane) {
        lane = lanes[laneId];
        if (lane.asset == address(0)) revert BPA_LaneMissing(laneId);
    }

    function _requireOpenPosition(address user, uint256 positionId)
        internal
        view
        returns (UserPosition storage pos)
    {
        pos = positions[user][positionId];
        if (pos.openedBlock == 0) revert BPA_PositionMissing(positionId);
        if (pos.closed) revert BPA_PositionClosed(positionId);
    }

    function _withinLaneBand(uint256 laneId, uint256 bps) internal view returns (bool) {
        LaneSheet storage lane = lanes[laneId];
        return bps >= lane.minReportBps && bps <= lane.maxReportBps;
    }

    function _laneHealthScoreInternal(uint256 laneId) internal view returns (uint256 score) {
        LaneSheet storage lane = lanes[laneId];
        if (lane.asset == address(0)) return 0;
        uint256 mean = BpaMath.weightedMean(lane.rollingSum, lane.rollingWeight);
        uint256 spread = laneWorstBps[laneId] == type(uint256).max
            ? 0
            : BpaMath.absDiff(laneBestBps[laneId], laneWorstBps[laneId]);
        uint256 density = lane.obsFilled * BpaMath.BPS_DENOM / OBS_RING_CAP;
        score = mean + density;
        if (spread > mean) {
            score = score > spread - mean ? score - (spread - mean) : 0;
        }
    }

    function _epochStats(uint256 laneId, uint256 epoch)
        internal
        view
        returns (uint256 meanBps, uint256 peakBps, uint256 floorBps, uint256 samples)
    {
        LaneSheet storage lane = lanes[laneId];
        uint256 sum;
        uint256 weightSum;
        peakBps = 0;
        floorBps = type(uint256).max;
        ObservationRing storage ring = obsRings[laneId];
        uint256 n = lane.obsFilled;
        for (uint256 i = 0; i < n; ++i) {
            uint256 idx = (lane.obsTail + i) % OBS_RING_CAP;
            ObsCell storage cell = ring.cells[idx];
            if (cell.epochTag != epoch) continue;
            samples += 1;
            sum += cell.bps * cell.weight;
            weightSum += cell.weight;
            if (cell.bps > peakBps) peakBps = cell.bps;
            if (cell.bps < floorBps) floorBps = cell.bps;
        }
        meanBps = BpaMath.weightedMean(sum, weightSum);
