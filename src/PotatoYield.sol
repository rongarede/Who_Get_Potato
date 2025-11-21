// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PotatoYield
 * @author Gemini
 * @notice An ERC20 token used to reward players for holding the Potato.
 * Only the main Potato contract can mint new tokens.
 */
contract PotatoYield is ERC20, Ownable {
    /**
     * @dev Initializes the ERC20 token and sets the owner.
     * The owner is expected to be the main Potato contract, which will be
     * the only entity allowed to mint new PotatoYield tokens.
     * @param _potatoContractAddress The address of the main Potato contract.
     */
    constructor(address _potatoContractAddress)
        ERC20("Potato Yield Token", "PYT")
        Ownable(_potatoContractAddress)
    {}

    /**
     * @notice Mints `amount` of PotatoYield tokens to `to`.
     * This function can only be called by the owner (the Potato contract).
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
