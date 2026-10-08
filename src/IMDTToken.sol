// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply IMDTEST token. The launch factory receives the entire supply.
/// @dev Distribution and pool configuration belong to the external launch factory.
contract IMDTToken is ERC20 {
    constructor() ERC20("IMDTEST", "IMDT") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
