// SPDX-License-Identifier: MIT
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
pragma solidity ^0.8.20;

error Unauthorized();
error Paused();
error NotEnough();

interface IVotingEscrowV2 {
    function transferFrom(address, address, uint256) external;
}
interface IVotingEscrowV3 {
    function createLock(address, uint256) external;
}

contract RamsesTokenMigrator {
    address public immutable multisig;
    address public immutable newRAM;
    address public immutable oldRAM;
    address public immutable oldVe;
    address public immutable newVe;

    uint256 public unlockCutOff;

    bool public paused;

    IERC20 private __ram;
    IERC20 private __new;
    IVotingEscrowV2 private __ve;
    IVotingEscrowV3 private __newVe;

    mapping(address => uint256) public ramMigrated;
    mapping(address => uint256) public veRamMigrated;

    modifier permissioned() {
        require(msg.sender == multisig, Unauthorized());
        _;
    }

    modifier notPaused() {
        require(!paused, Paused());
        _;
    }

    event MigratedRam(address indexed migrator, uint256 _amount);

    constructor(
        address _multisig,
        address _newRAM,
        address _oldRAM,
        address _newVe,
        address _oldVe
    ) {
        multisig = _multisig;
        newRAM = _newRAM;
        oldRAM = _oldRAM;
        newVe = _newVe;
        oldVe = _oldVe;

        paused = true;

        __ram = IERC20(oldRAM);
        __new = IERC20(newRAM);
        __ve = IVotingEscrowV2(oldVe);
        __newVe = IVotingEscrowV3(newVe);
    }

    function migrateTokenSimple(uint256 _amount) external notPaused {
        /// @dev ensure the balance of oldRAM is enough
        require(__ram.balanceOf(msg.sender) >= _amount, NotEnough());
        /// @dev "burn" to the 0xdead address
        __ram.transferFrom(msg.sender, address(0xdead), _amount);
        /// @dev send newRAM to the user
        __new.transfer(msg.sender, _amount);
        /// @dev add in mapping
        ramMigrated[msg.sender] += _amount;

        emit MigratedRam(msg.sender, _amount);
    }

    function migrateVe(uint256 _tokenId) external notPaused {}

    function pause(bool _tf) external permissioned {
        paused = _tf;
    }

    function setCutOff(uint256 _lengthInSeconds) external permissioned {
        unlockCutOff = _lengthInSeconds;
    }
}
