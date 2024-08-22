// SPDX-License-Identifier: MIT
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
pragma solidity ^0.8.20;

/// @dev error strings for require statements
error Unauthorized();
error Paused();
error NotEnough();
error AlreadyLabeled();
error NoLabel();
error Migrated();
error Failed();

/// @dev minimized ve2 use for contract
interface IVotingEscrowV2 {
    function transferFrom(address from, address to, uint256 _amount) external;
    function locked(uint256) external view returns (int128, uint);
    function ownerOf(uint256) external view returns (address);
}
/// @dev minimized ve3 use for contract
interface IVotingEscrowV3 {
    function createLock(address, uint256) external;
}

contract RamsesTokenMigrator {
    /// @notice address of the multisig
    address public immutable multisig;
    /// @notice new RAM contract
    address public immutable newRAM;
    /// @notice old RAM contract
    address public immutable oldRAM;
    /// @notice old VotingEscrow
    address public immutable oldVe;
    /// @notice new VotingEscrow
    address public immutable newVe;

    /// @notice assigned bot to arbitrage
    address public arbitrager;
    /// @notice timestamp where liquid assets are given for VotingEscrow veNFTs
    uint256 public unlockCutOff;
    /// @notice whether migrations are paused
    bool public paused;

    /// @dev private variables for contract use
    IERC20 private _ram;
    IERC20 private _new;
    IVotingEscrowV2 private _ve;
    IVotingEscrowV3 private _newVe;

    /// @notice mapping that holds amount of RAM tokens migrated
    mapping(address => uint256) public ramMigrated;
    /// @notice mapping that holds amount of veRAM that was migrated
    mapping(address => uint256) public veRamMigrated;

    /// @notice mapping that shows if a partnerNft was migrated
    mapping(uint256 => bool) public partnerNfts;
    /// @notice mapping that tracks if any veNFT Id was migrated
    mapping(uint256 => bool) public migratedNft;

    /// @dev permissioned modifier for multisig interactions
    modifier permissioned() {
        require(msg.sender == multisig, Unauthorized());
        _;
    }

    /// @dev permissioned modifier for arbitrager interactions
    modifier arbitrage() {
        require(msg.sender == arbitrager, Unauthorized());
        _;
    }

    /// @dev modifier that only allows migrations when not paused
    modifier notPaused() {
        require(!paused, Paused());
        _;
    }

    event MigratedRam(address indexed _migrator, uint256 _amount);
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
        /// @dev initialize immutables
        multisig = _multisig;
        newRAM = _newRAM;
        oldRAM = _oldRAM;
        newVe = _newVeAddress;
        oldVe = _oldVe;

        /// @dev start paused by default
        paused = true;

        /// @dev initialize the private variables
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
        /// @dev send to current contract
        _ram.transferFrom(msg.sender, address(this), _amount);
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
                /// @dev give approval to votingEscrow
                _new.approve(address(_newVe), _amount);
                /// @dev create new lock, burns tokens
                _newVe.createLock(msg.sender, _amount);
                /// @dev update mapping
                veRamMigrated[msg.sender] += _amount;
                /// @dev register veNFT as migrated in the mapping
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

    /// @notice perform an arbitrage on the price discrepancy between the old token and new token
    /// @param _router address of the aggregation router (odos typically)
    /// @param _routingData the bytes data of the swap routes
    function perform(
        address _router,
        bytes calldata _routingData
    ) external arbitrage {
        (uint256 oldRamBalanceBefore, uint256 newRamBalanceBefore) = (
            _ram.balanceOf(address(this)),
            _new.balanceOf(address(this))
        );

        /// @dev give approval to the router temporarily
        _ram.approve(_router, oldRamBalanceBefore);
        /// @dev ensure the arbitrary call succeeds
        (bool success, ) = _router.call(_routingData);
        require(success, Failed());
        /// @dev set approval back to 0
        _ram.approve(_router, 0);
        uint256 differential = ((_new.balanceOf(address(this)) -
            newRamBalanceBefore) -
            (oldRamBalanceBefore - _ram.balanceOf(address(this))));
        /// @dev require the differential is > 0
        require(differential > 0, Failed());
        /// @dev send to multisig to be burned or repurposed
        _new.transfer(multisig, differential);
    }
}
