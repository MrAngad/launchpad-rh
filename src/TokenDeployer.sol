// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {LaunchToken} from "./LaunchToken.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";

/// @title TokenDeployer
/// @notice Deploys launch tokens at predictable CREATE2 addresses. It's a separate contract only because the
///         factory can't fit the token's creation code under EIP-170's size limit. Only its factory may call it,
///         so every token at one of its CREATE2 addresses is a real launch of that factory.
contract TokenDeployer {
    /// @notice The factory that deploys through this contract, and that every token's supply mints to.
    address public immutable factory;

    /// @notice Only the factory deploys.
    error NotFactory();

    /// @param factory_ The factory, deployed next at its predicted address (it checks the pairing).
    constructor(address factory_) {
        factory = factory_;
    }

    /// @notice Deploys a token whose whole supply mints to the factory, at the CREATE2 address of `salt`.
    function deploy(bytes32 salt, ILaunchToken.Metadata calldata metadata, address creator)
        external
        returns (LaunchToken)
    {
        if (msg.sender != factory) {
            revert NotFactory();
        }
        return LaunchToken(Create2.deploy(0, salt, _initCode(metadata, creator)));
    }

    /// @notice The address `deploy` would give a token at `salt`.
    function predict(bytes32 salt, ILaunchToken.Metadata calldata metadata, address creator)
        external
        view
        returns (address)
    {
        return Create2.computeAddress(salt, keccak256(_initCode(metadata, creator)));
    }

    /// @dev The token's creation code with its constructor arguments, used both to deploy and to predict.
    function _initCode(ILaunchToken.Metadata calldata metadata, address creator) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(LaunchToken).creationCode,
            abi.encode(
                metadata.name, metadata.symbol, metadata.logo, metadata.description, metadata.socials, creator, factory
            )
        );
    }
}
