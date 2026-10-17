// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {ILaunchToken, LAUNCH_SUPPLY} from "./interfaces/ILaunchToken.sol";

/// @title LaunchToken
/// @notice A launch's fixed-supply ERC-20. The whole supply mints to the factory, which sells it on the curve.
///         Metadata is fixed at creation and capped in length. `creator` is for attribution and may propose a new
///         fee recipient; it has no power over the token. Any holder may burn their own balance.
contract LaunchToken is ILaunchToken, ERC20, ERC20Burnable {
    /// @notice The fixed supply, all minted to the factory: one billion tokens with 18 decimals.
    uint256 public constant SUPPLY = LAUNCH_SUPPLY;

    /// @notice The longest name, in bytes.
    uint256 public constant MAX_NAME_LENGTH = 64;

    /// @notice The longest symbol, in bytes.
    uint256 public constant MAX_SYMBOL_LENGTH = 16;

    /// @notice The longest logo (a URL or IPFS CID), in bytes.
    uint256 public constant MAX_LOGO_LENGTH = 512;

    /// @notice The longest description, in bytes.
    uint256 public constant MAX_DESCRIPTION_LENGTH = 2048;

    /// @notice The longest of each social link, in bytes.
    uint256 public constant MAX_SOCIAL_LENGTH = 256;

    /// @inheritdoc ILaunchToken
    address public immutable factory;

    /// @inheritdoc ILaunchToken
    address public creator;

    /// @notice The token's logo: a URL or an IPFS CID. Fixed at creation.
    string public logo;

    /// @notice The token's description. Fixed at creation.
    string public description;

    /// @inheritdoc ILaunchToken
    /// @dev Fixed at creation.
    Socials public socials;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address creator_,
        address factory_
    ) ERC20(name_, symbol_) {
        if (creator_ == address(0)) {
            revert ZeroAddress(); // a zero factory is refused by the mint
        }
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert EmptyMetadata();
        }
        if (
            bytes(name_).length > MAX_NAME_LENGTH || bytes(symbol_).length > MAX_SYMBOL_LENGTH
                || bytes(logo_).length > MAX_LOGO_LENGTH || bytes(description_).length > MAX_DESCRIPTION_LENGTH
                || bytes(socials_.twitter).length > MAX_SOCIAL_LENGTH || bytes(socials_.telegram).length > MAX_SOCIAL_LENGTH
                || bytes(socials_.discord).length > MAX_SOCIAL_LENGTH || bytes(socials_.website).length > MAX_SOCIAL_LENGTH
                || bytes(socials_.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert MetadataTooLong();
        }
        factory = factory_;
        creator = creator_;
        logo = logo_;
        description = description_;
        socials = socials_;
        _mint(factory_, SUPPLY);
    }

    /// @inheritdoc ILaunchToken
    function transferCreator(address newCreator) external override {
        if (msg.sender != creator) {
            revert NotCreator();
        }
        if (newCreator == address(0)) {
            revert ZeroAddress();
        }
        emit CreatorTransferred(creator, newCreator);
        creator = newCreator;
        ILaunchFactory(factory).feeManager().dropPendingFeeRecipient(); // the old creator's proposal goes with it
    }

    /// @inheritdoc ILaunchToken
    function getTokenInfo()
        external
        view
        returns (
            address tokenCreator,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (creator, logo, description, socials);
    }

    /// @inheritdoc ILaunchToken
    function burn(uint256 amount) public override(ERC20Burnable, ILaunchToken) {
        ERC20Burnable.burn(amount);
    }
}
