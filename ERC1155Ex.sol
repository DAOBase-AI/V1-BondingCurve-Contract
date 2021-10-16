// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// 增强型ERC1155，记录了某用户拥有的所有token ID
contract ERC1155Ex is ERC1155 {
    using EnumerableSet for EnumerableSet.UintSet;
    
    address public curve;
    uint256 public totalSupply;         // 总流通量
    uint256 public tokenId;
    mapping(address => EnumerableSet.UintSet) private userTokenIds;   // 记录用户拥有的tokenId
    
    constructor (string memory _baseUri) ERC1155(_baseUri) {
        curve = msg.sender;
    }
    
    // 给_to铸造ERC1155，数量_balance
    function mint(address _to, uint256 _balance) public returns(uint256) {
        require(msg.sender == curve, "ERC1155Ex: Minter is not the curve");
        tokenId += 1;
        _mint(_to, tokenId, _balance, "");
        totalSupply += _balance;
        userTokenIds[_to].add(tokenId);
        return tokenId;
    }
    
    // 销毁_to拥有的ERC1155, ID为_tokenId，销毁数量为_balance
    function burn(address _to, uint256 _tokenId, uint256 _balance) public {
        require(msg.sender == curve, "ERC1155Ex: Minter is not the curve");
        _burn(_to, _tokenId, _balance);
        totalSupply -= _balance;
        if (balanceOf(_to, _tokenId) == 0) {
            userTokenIds[_to].remove(_tokenId);
        }
    }
    
    // 批量销毁
    function burnBatch(address _to, uint256[] memory _tokenIds, uint256[] memory _balances) public {
        require(msg.sender == curve, "ERC1155Ex: Minter is not the curve");
        
        _burnBatch(_to, _tokenIds, _balances);
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            totalSupply -= _balances[i];
            if (balanceOf(_to, _tokenIds[i]) == 0) {
                userTokenIds[_to].remove(_tokenIds[i]);
            }    
        }
    }

    // 获取某个用户拥有的ERC1155 token ID总数
    function getUserTokenIdNumber(address _userAddr) public view returns(uint256) {
        return userTokenIds[_userAddr].length();
    }
    
    // 通过用户地址和序号获取tokenId
    function getUserTokenId(address _userAddr, uint256 _index) public view returns(uint256) {
        return userTokenIds[_userAddr].at(_index);
    }
}