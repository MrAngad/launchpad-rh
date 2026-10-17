// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// The fixed supply of every launch token: one billion, 18 decimals. The single source for every contract.
uint256 constant LAUNCH_SUPPLY = 1_000_000_000e18;

/// @title ILaunchToken
/// @notice A launch's fixed-supply ERC-20, with metadata fixed at creation and a creator role (attribution, and
///         proposing a new fee recipient). Burnable: any holder may burn its own balance.
interface ILaunchToken is IERC20Metadata {
    /// @notice The five social links; any may be empty.
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    /// @notice A token's name and symbol (never empty), logo URL or CID, description and socials, each capped.
    struct Metadata {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
    }

    /// @notice The creator role moved.
    event CreatorTransferred(address indexed previousCreator, address indexed newCreator);

    /// @notice The creator cannot be the zero address.
    error ZeroAddress();

    /// @notice A metadata field is over its length cap.
    error MetadataTooLong();

    /// @notice The name or the symbol is empty.
    error EmptyMetadata();

    /// @notice Only the creator may hand the role on.
    error NotCreator();

    /// @notice Hands the creator role on and drops any pending fee-recipient proposal. Creator only. Any non-zero
    ///         address is accepted, even one that could never use the role.
    function transferCreator(address newCreator) external;

    /// @notice Burns `amount` of the caller's balance.
    function burn(uint256 amount) external;

    /// @notice The factory that minted the supply and sells the token on its curve.
    /// @dev Not proof of a launch: anyone can deploy this contract naming any factory. Trust a token only if a
    ///      factory you already know says so (`launches(token).created`).
    function factory() external view returns (address);

    /// @notice The launch's creator: attribution, and who may propose a new fee recipient. No power over the token.
    function creator() external view returns (address);

    /// @notice The five social fields.
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        );

    /// @notice Creator and metadata in one call.
    function getTokenInfo()
        external
        view
        returns (
            address tokenCreator,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        );
}
