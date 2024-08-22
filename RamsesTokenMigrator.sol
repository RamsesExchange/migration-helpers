// SPDX-License-Identifier: MIT
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
pragma solidity ^0.8.20;

error Unauthorized();
error Paused();
error NotEnough();
error AlreadyLabeled();
error NoLabel();
error Migrated();

interface IVotingEscrowV2 {
    function transferFrom(address, address, uint256) external;
    function locked(uint256) external view returns (int128, uint);
    function ownerOf(uint) external view returns (address);
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

    IERC20 private _ram;
    IERC20 private _new;
    IVotingEscrowV2 private _ve;
    IVotingEscrowV3 private _newVe;

    mapping(address => uint256) public ramMigrated;
    mapping(address => uint256) public veRamMigrated;

    mapping(uint256 => bool) public partnerNfts;
    mapping(uint256 => bool) public migratedNft;

    modifier permissioned() {
        require(msg.sender == multisig, Unauthorized());
        _;
    }

    modifier notPaused() {
        require(!paused, Paused());
        _;
    }

    event MigratedRam(address indexed migrator, uint256 _amount);
    event veMigrated(
        address indexed migrator,
        uint256 _tokenId,
        uint256 _amount
    );
    event PartnerNftDeposited(
        address indexed sender,
        uint256 indexed tokenId,
        address indexed origin
    );

    event Labeled(uint256[]);
    event LabelRemoved(uint256);

    constructor(
        address _multisig,
        address _newRAM,
        address _oldRAM,
        address _newVeAddress,
        address _oldVe
    ) {
        multisig = _multisig;
        newRAM = _newRAM;
        oldRAM = _oldRAM;
        newVe = _newVeAddress;
        oldVe = _oldVe;

        paused = true;

        _ram = IERC20(oldRAM);
        _new = IERC20(newRAM);
        _ve = IVotingEscrowV2(oldVe);
        _newVe = IVotingEscrowV3(newVe);
    }

    /// @notice migrate RAM for the new RAM token
    /// @param _amount the amount of tokens to migrate
    function migrateToken(uint256 _amount) external notPaused {
        /// @dev ensure the balance of oldRAM is enough
        require(_ram.balanceOf(msg.sender) >= _amount, NotEnough());
        /// @dev "burn" to the 0xdead address
        _ram.transferFrom(msg.sender, address(0xdead), _amount);
        /// @dev send newRAM to the user
        _new.transfer(msg.sender, _amount);
        /// @dev add in mapping
        ramMigrated[msg.sender] += _amount;

        emit MigratedRam(msg.sender, _amount);
    }

    /// @notice migrate a veNFT position ,liquid or ve returned based on unlock time
    /// @param _tokenId the veNFT Ids
    function migrateVe(uint256[] calldata _tokenId) external notPaused {
        for (uint256 i = 0; i < _tokenId.length; ++i) {
            require(msg.sender == _ve.ownerOf(_tokenId[i]), Unauthorized());
            (int128 lockAmount, uint256 timeEnd) = _ve.locked(_tokenId[i]);
            uint256 _amount = uint256(int256(lockAmount));
            bool treatAsLiquid = (timeEnd <= unlockCutOff);

            _ve.transferFrom(msg.sender, multisig, _tokenId[i]);
            /// @dev if the veNFT unlock time is less than unlockCutOff
            if (treatAsLiquid) {
                _new.transfer(msg.sender, _amount);
                ramMigrated[msg.sender] += _amount;
                emit MigratedRam(msg.sender, _amount);
            } else {
                _newVe.createLock(msg.sender, _amount);
                veRamMigrated[msg.sender] += _amount;
                migratedNft[_tokenId[i]] = true;
                emit veMigrated(msg.sender, _tokenId[i], _amount);
            }
        }
    }

    /// @notice for legacy partner NFTs to deposit for migration
    /// @param _tokenId the veNFT Id
    function depositPartnerNft(uint256 _tokenId) external notPaused {
        require(msg.sender == _ve.ownerOf(_tokenId), Unauthorized());
        require(partnerNfts[_tokenId], Unauthorized());
        _ve.transferFrom(msg.sender, multisig, _tokenId);
        emit PartnerNftDeposited(msg.sender, _tokenId, tx.origin);
    }

    /// @notice add a partner label on Nfts
    /// @param _tokenId the veNFT Ids
    function label(uint256[] calldata _tokenId) external permissioned {
        for (uint256 i = 0; i < _tokenId.length; ++i) {
            require(!partnerNfts[_tokenId[i]], AlreadyLabeled());
            partnerNfts[_tokenId[i]] = true;
        }
        emit Labeled(_tokenId);
    }

    /// @notice remove a partner label on an Nft
    /// @param _tokenId the veNFT Id
    function wipeLabel(uint256 _tokenId) external permissioned {
        require(partnerNfts[_tokenId], NoLabel());
        require(!migratedNft[_tokenId], Migrated());
        partnerNfts[_tokenId] = false;
        emit LabelRemoved(_tokenId);
    }

    /// @notice pauses the contract
    /// @param _tf true or false
    function pause(bool _tf) external permissioned {
        paused = _tf;
    }

    /// @notice sets the cutOff time for checking if veNFT's are to be treated as liquid or locked
    /// @param _ts the unixTimestamp
    function setCutOff(uint256 _ts) external permissioned {
        unlockCutOff = _ts;
    }
}
