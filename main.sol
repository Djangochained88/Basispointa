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
