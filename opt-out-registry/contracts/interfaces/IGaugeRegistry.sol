// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGaugeRegistry
/// @notice Shared interface of the CVX gauge registries.
/// @dev The two deployments, by their on-chain `name()`:
///      - "Curve Gauge Registry": 0x96b24E0534B0cA31D8523D4be4904747Fd579D95
///      - "Fx Gauge Registry":    0xC2F99261d84D1665Df7e50F46813497A737AfB20
///      They expose an identical surface; the f(x) one adds two unused pool-type constants.
///      Both are owned by 0xcc07E8Ba6bC8aeb18c4ae110c3dA9c7dcE4A3e74 (Convex core), a different
///      address from the one owning vlCVX but the same trust domain — so depending on the
///      registry adds no counterparty beyond the one the locker already requires.
///
///      Note `setGauge` is permissionless: anyone may de-register a gauge Curve has killed.
///      That is harmless here, since a killed gauge cannot be voted for, so there is nothing to
///      exclude and no reason to read or write an opt-out against it.
interface IGaugeRegistry {
    /// @notice True when the gauge currently holds a slot in `activeGauges`.
    /// @dev A plain `activeGaugeIndex[_gauge] > 0` storage read. This is the only
    ///      validity check that is safe to call on an arbitrary address, and it already
    ///      returns false for force-removed gauges because `forceRemove` zeroes the index.
    function isRegisteredGauge(address _gauge) external view returns (bool);

    /// @notice Live validity check against the gauge controller.
    /// @dev WARNING: this REVERTS for addresses the controller does not know
    ///      (`gauge_types` reverts) and for non-contracts (`is_killed` reverts). It is
    ///      never called by OptOutRegistry; `isRegisteredGauge` is used instead.
    function isValidGauge(address _gauge) external view returns (bool);

    function activeGauges(uint256 _index) external view returns (address);
    function activeGaugeIndex(address _gauge) external view returns (uint256);
    function gaugeLength() external view returns (uint256);
    function forceRemoved(address _gauge) external view returns (bool);
    function gaugeController() external view returns (address);
    function name() external view returns (string memory);
}
