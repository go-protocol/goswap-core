// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './GoSwapERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IGoSwapFactory.sol';
import './interfaces/IGoSwapPair.sol';
import './interfaces/IGoSwapCallee.sol';

/**
 * @title 迁移合约接口
 */
interface IMigrator {
    // Return the desired amount of liquidity token that the migrator wants.
    function desiredLiquidity() external view returns (uint256);
}

/**
 * @title 交易钩子合约接口
 */
interface IGoSwapHook {
    function swapHook(
        address sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external;
}

/**
 * @title 保险库合约接口
 */
interface IVault {
    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function deposit(uint256) external;

    function withdraw(uint256) external;

    function balance() external view returns (uint256);
}

/**
 * @title GoSwap 配对合约
 */
contract GoSwapPair is GoSwapERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;

    /// @notice 最小流动性 = 1000
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;
    /// @dev transfer的selector编码
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    /// @notice 工厂合约地址
    address public factory;
    /// @dev token地址数组
    address[2] private tokens;

    /// @notice 保险柜地址
    address[2] public vaults;
    /// @notice 存款比例
    uint16[2] public redepositRatios;
    /// @notice 存款数额
    uint256[2] public depositeds;
    /// @notice 虚流动性
    uint112[2] public dummys;

    /// @notice 收税地址
    address public feeTo; // feeTo
    /// @notice 配对创建者
    address public creator; // creator
    /// @notice 交易钩子合约地址
    address public swapHookAddress;

    /// @dev token储备量
    uint112[2] private reserves; // uses single storage slot, accessible via getReserves
    /// @dev 更新储备量的最后时间戳
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    /// @notice 配对合约创建时间
    uint256 public birthday;
    /// @dev token价格最后累计
    uint256[2] private priceCumulativeLasts;
    /// @notice 在最近一次流动性事件之后的K值,储备量0*储备量1，自最近一次流动性事件发生后
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    /// @notice 流动性相当于sqrt（k）增长的1/6
    uint8 public rootKmul = 5; // mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    /// @notice 手续费占比0.3%
    uint8 public fee = 3; // 0.3%

    /// @dev 防止重入开关
    uint256 private unlocked = 1;

    /**
     * @dev 事件:铸造
     * @param sender 发送者
     * @param amount0 输入金额0
     * @param amount1 输入金额1
     */
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    /**
     * @dev 事件:销毁
     * @param sender 发送者
     * @param amount0 输入金额0
     * @param amount1 输入金额1
     * @param to to地址
     */
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    /**
     * @dev 事件:交换
     * @param sender 发送者
     * @param amount0In 输入金额0
     * @param amount1In 输入金额1
     * @param amount0Out 输出金额0
     * @param amount1Out 输出金额1
     * @param to to地址
     */
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    /**
     * @dev 事件:同步
     * @param reserve0 储备量0
     * @param reserve1 储备量1
     */
    event Sync(uint112 reserve0, uint112 reserve1);

    /**
     * @dev 事件:存款更新
     * @param deposited0 存款数量0
     * @param deposited1 存款数量1
     */
    event DepositedUpdated(uint256 deposited0, uint256 deposited1);

    /**
     * @dev 事件:保险库更新
     * @param tokenIndex token索引
     * @param vault 保险库地址
     */
    event VaultUpdated(uint8 tokenIndex, address indexed vault);
    /**
     * @dev 事件:存款比例更新
     * @param tokenIndex token索引
     * @param ratio 保险库地址
     */
    event RedepositRatioUpdated(uint8 tokenIndex, uint16 ratio);

    /**
     * @dev 事件:铸造虚流动性
     * @param amount0 数额0
     * @param amount1 数额1
     */
    event DummyMint(uint256 amount0, uint256 amount1);

    /**
     * @dev 事件:销毁虚流动性
     * @param amount0 数额0
     * @param amount1 数额1
     */
    event DummyBurn(uint256 amount0, uint256 amount1);

    /**
     * @dev 事件:收税地址更新
     * @param feeTo 收税地址
     */
    event FeeToUpdated(address indexed feeTo);

    /**
     * @dev 事件:K值乘数更新
     * @param rootKmul K值乘数
     */
    event RootKmulUpdated(uint8 rootKmul);

    /**
     * @dev 事件:交易钩子合约地址更新
     * @param swapHookAddress 交易钩子合约地址
     */
    event SwapHookUpdated(address swapHookAddress);


    /**
     * @dev 事件:收税比例更新
     * @param fee 收税比例
     */
    event FeeUpdated(uint8 fee);

    /**
     * @dev 修饰符:锁定运行防止重入
     */
    modifier lock() {
        require(unlocked == 1, 'GoSwap: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**
     * @dev 修饰符:确认必须为工厂合约的FeeToSetter地址
     */
    modifier onlyFeeToSetter() {
        // 确认必须为工厂合约的FeeToSetter地址
        require(msg.sender == IGoSwapFactory(factory).feeToSetter(), 'GoSwap: FORBIDDEN');
        _;
    }

    /**
     * @dev 返回token0地址
     */
    function token0() public view returns (address) {
        return tokens[0];
    }

    /**
     * @dev 返回token1地址
     */
    function token1() public view returns (address) {
        return tokens[1];
    }

    /**
     * @dev 返回price0CumulativeLast
     */
    function price0CumulativeLast() public view returns (uint256) {
        return priceCumulativeLasts[0];
    }

    /**
     * @dev 返回price1CumulativeLast
     */
    function price1CumulativeLast() public view returns (uint256) {
        return priceCumulativeLasts[1];
    }

    /**
     * @dev 获取储备
     * @return _reserve0 储备量0
     * @return _reserve1 储备量1
     * @return _blockTimestampLast 时间戳
     */
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserves[0];
        _reserve1 = reserves[1];
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     * @dev 获取存款数额
     * @return 存款数额0
     * @return 存款数额1
     */
    function getDeposited() public view returns (uint256, uint256) {
        return (depositeds[0], depositeds[1]);
    }

    /**
     * @dev 获取虚流动性
     * @return 虚流动性0
     * @return 虚流动性1
     */
    function getDummy() public view returns (uint256, uint256) {
        return (dummys[0], dummys[1]);
    }

    /**
     * @dev 私有安全发送
     * @param tokenIndex token索引
     * @param to    to地址
     * @param value 数额
     */
    function _safeTransfer(
        uint8 tokenIndex,
        address to,
        uint256 value
    ) private {
        // 获取当前合约在token中的余额
        uint256 balance = IERC20(tokens[tokenIndex]).balanceOf(address(this));
        bool success;
        bytes memory data;
        // 如果余额<发送数额
        if (balance < value) {
            // 将存款从保险库中全部取出
            _withdrawAll(tokenIndex);
            //调用token合约地址的低级transfer方法
            (success, data) = tokens[tokenIndex].call(abi.encodeWithSelector(SELECTOR, to, value));
            // 如果存款比例>0
            if (redepositRatios[tokenIndex] > 0) {
                // 重新存款进入保险库
                _redeposit(tokenIndex);
            }
        } else {
            //调用token合约地址的低级transfer方法
            (success, data) = tokens[tokenIndex].call(abi.encodeWithSelector(SELECTOR, to, value));
        }
        //确认返回值为true并且返回的data长度为0或者解码后为true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'GoSwap: TRANSFER_FAILED');
    }

    /**
     * @dev 构造函数
     */
    constructor() public {
        //factory地址为合约布署者
        factory = msg.sender;
        birthday = block.timestamp;
    }

    /**
     * @dev 初始化方法,部署时由工厂调用一次
     * @param _token0 token0
     * @param _token1 token1
     */
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'GoSwap: FORBIDDEN'); // sufficient check
        tokens[0] = _token0;
        tokens[1] = _token1;
        symbol = string(abi.encodePacked('GLP:', IERC20GoSwap(_token0).symbol(), '-', IERC20GoSwap(_token1).symbol()));
    }

    /**
     * @dev 设置收税地址
     * @param _feeTo 收税地址
     */
    function setFeeTo(address _feeTo) external onlyFeeToSetter {
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    /**
     * @dev 设置K值乘数
     * @param _rootKmul K值乘数
     */
    function setRootKmul(uint8 _rootKmul) external onlyFeeToSetter {
        rootKmul = _rootKmul;
        emit RootKmulUpdated(_rootKmul);
    }

    /**
     * @dev 设置收税比例
     * @param _fee 收税比例
     */
    function setFee(uint8 _fee) external onlyFeeToSetter {
        fee = _fee;
        emit FeeUpdated(fee);
    }

    /**
     * @dev 设置交易钩子合约地址
     * @param _swapHookAddress 交易钩子合约地址
     */
    function setSwapHook(address _swapHookAddress) external onlyFeeToSetter {
        swapHookAddress = _swapHookAddress;
        emit SwapHookUpdated(swapHookAddress);
    }

    /**
     * @dev 获取收税地址
     * @return 收税地址
     */
    function getFeeTo() public view returns (address) {
        // 如果feeTo地址不为0地址,以feeTo地址为准
        if (feeTo != address(0)) {
            return feeTo;
            // 否则如果配对合约创建30天之后,以工程合约的feeTo地址为准
        } else if (block.timestamp.sub(birthday) > 30 days) {
            return IGoSwapFactory(factory).feeTo();
            // 否者feeTo地址为配对合约创建者
        } else {
            return creator;
        }
    }

    /**
     * @dev 更新储量，并在每个区块的第一次调用时更新价格累加器
     * @param balance0 余额0
     * @param balance1  余额1
     * @param _reserve0 储备0
     * @param _reserve1 储备1
     */
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        //确认余额0和余额1小于等于最大的uint112
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'GoSwap: OVERFLOW');
        //区块时间戳,将时间戳转换为uint32
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        //计算时间流逝
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //如果时间流逝>0 并且 储备量0,1不等于0
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            //价格0最后累计 += 储备量1 * 2**112 / 储备量0 * 时间流逝
            priceCumulativeLasts[0] += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            //价格1最后累计 += 储备量0 * 2**112 / 储备量1 * 时间流逝
            priceCumulativeLasts[1] += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //余额0,1放入储备量0,1
        reserves[0] = uint112(balance0);
        reserves[1] = uint112(balance1);
        //更新最后时间戳
        blockTimestampLast = blockTimestamp;
        //触发同步事件
        emit Sync(reserves[0], reserves[1]);
    }

    /**
     * @dev 默认情况下铸造流动性相当于1/6的增长sqrt（k）
     * @param _reserve0 储备0
     * @param _reserve1 储备1
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private {
        //定义k值
        uint256 _kLast = kLast; // gas savings
        //如果k值不等于0
        if (_kLast != 0 && rootKmul > 0) {
            //计算(_reserve0*_reserve1)的平方根
            uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
            //计算k值的平方根
            uint256 rootKLast = Math.sqrt(_kLast);
            //如果rootK>rootKLast
            if (rootK > rootKLast) {
                //分子 = erc20总量 * (rootK - rootKLast)
                uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                //分母 = rootK * 5 + rootKLast
                uint256 denominator = rootK.mul(rootKmul).add(rootKLast);
                //流动性 = 分子 / 分母
                uint256 liquidity = numerator / denominator;
                // 如果流动性 > 0 将流动性铸造给feeTo地址
                if (liquidity > 0) _mint(getFeeTo(), liquidity);
            }
        }
    }

    /**
     * @dev 铸造方法
     * @param to to地址
     * @return liquidity 流动性数量
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    function mint(address to) external lock returns (uint256 liquidity) {
        //获取`储备量0`,`储备量1`
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //获取当前合约在token0合约内的余额
        uint256 balance0 = balanceOfIndex(0);
        //获取当前合约在token1合约内的余额
        uint256 balance1 = balanceOfIndex(1);
        //amount0 = 余额0
        uint256 amount0 = balance0.sub(_reserve0);
        //amount1 = 余额1
        uint256 amount1 = balance1.sub(_reserve1);
        // 储备量0 - 虚流动性0
        _reserve0 -= dummys[0];
        // 储备量1 - 虚流动性1
        _reserve1 -= dummys[1];

        //调用铸造费方法
        _mintFee(_reserve0, _reserve1);
        //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //如果_totalSupply等于0,首次创建配对
        if (_totalSupply == 0) {
            // 定义迁移合约,从工厂合约中调用迁移合约的地址
            address migrator = IGoSwapFactory(factory).migrator();
            // 如果调用者是迁移合约(说明是正在执行迁移操作)
            if (msg.sender == migrator) {
                // 流动性 = 迁移合约中的`需求流动性数额`,这个数额在交易开始之前是无限大,交易过程中调整为lpToken迁移到数额,交易结束之后又会被调整回无限大
                liquidity = IMigrator(migrator).desiredLiquidity();
                // 确认流动性数额大于0并且不等于无限大
                require(liquidity > 0 && liquidity != uint256(-1), 'Bad desired liquidity');
                // 否则
            } else {
                // 确认迁移地址等于0地址(说明不在迁移过程中,属于交易所营业后的创建流动性操作)
                require(migrator == address(0), 'Must not have migrator');
                //流动性 = (数量0 * 数量1)的平方根 - 最小流动性1000
                liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
                //在总量为0的初始状态,永久锁定最低流动性
                _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            }
            // 设置配对创建者为to地址
            creator = to; // set creator
        } else {
            //流动性 = 最小值 (amount0 * _totalSupply / _reserve0) 和 (amount1 * _totalSupply / _reserve1)
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        //确认流动性 > 0
        require(liquidity > 0, 'GoSwap: INSUFFICIENT_LIQUIDITY_MINTED');
        //铸造流动性给to地址
        _mint(to, liquidity);
        // 储备量0 + 虚流动性0
        _reserve0 += dummys[0];
        // 储备量1 + 虚流动性1
        _reserve1 += dummys[1];

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //k值 = 储备0 * 储备1,储备量中包含虚流动性,所以要再减去
        kLast = uint256(reserves[0] - dummys[0]).mul(reserves[1] - dummys[1]); // reserve0 and reserve1 are up-to-date
        //触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @dev 销毁方法
     * @param to to地址
     * @return amount0
     * @return amount1
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        //获取`储备量0`,`储备量1`
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //获取当前合约在token0合约内的余额
        uint256 balance0 = balanceOfIndex(0).sub(dummys[0]);
        //获取当前合约在token1合约内的余额
        uint256 balance1 = balanceOfIndex(1).sub(dummys[1]);
        //从当前合约的balanceOf映射中获取当前合约自身的流动性数量,移除流动性的之前先将lptoken发送到配对合约
        uint256 liquidity = balanceOf[address(this)];

        //调用铸造费方法
        _mintFee(_reserve0 - dummys[0], _reserve1 - dummys[1]);
        //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //amount0 = 流动性数量 * 余额0 / totalSupply   使用余额确保按比例分配
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        //amount1 = 流动性数量 * 余额1 / totalSupply   使用余额确保按比例分配
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        //确认amount0和amount1都大于0
        require(amount0 > 0 && amount1 > 0, 'GoSwap: INSUFFICIENT_LIQUIDITY_BURNED');
        //销毁当前合约内的流动性数量
        _burn(address(this), liquidity);
        //将amount0数量的_token0发送给to地址
        _safeTransfer(0, to, amount0);
        //将amount1数量的_token1发送给to地址
        _safeTransfer(1, to, amount1);
        //更新balance0
        balance0 = balanceOfIndex(0);
        //更新balance1
        balance1 = balanceOfIndex(1);

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //k值 = 储备0 * 储备1,储备量中包含虚流动性,所以要再减去
        kLast = uint256(reserves[0] - dummys[0]).mul(reserves[1] - dummys[1]); // reserve0 and reserve1 are up-to-date
        //触发销毁事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @dev 铸造虚流动性
     * @param amount0 数额0
     * @param amount1 数额1
     */
    function dummyMint(uint256 amount0, uint256 amount1) external onlyFeeToSetter lock {
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // 虚流动性0 + 数额0
        dummys[0] += uint112(amount0);
        // 虚流动性1 + 数额1
        dummys[1] += uint112(amount1);
        //更新储备量
        _update(balanceOfIndex(0), balanceOfIndex(1), _reserve0, _reserve1);
        emit DummyMint(amount0, amount1);
    }

    /**
     * @dev 销毁虚流动性
     * @param amount0 数额0
     * @param amount1 数额1
     */
    function dummyBurn(uint256 amount0, uint256 amount1) external onlyFeeToSetter lock {
        // 获取储备量
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // 虚流动性0 - 数额0
        dummys[0] -= uint112(amount0);
        // 虚流动性1 - 数额1
        dummys[1] -= uint112(amount1);
        //更新储备量
        _update(balanceOfIndex(0), balanceOfIndex(1), _reserve0, _reserve1);
        emit DummyBurn(amount0, amount1);
    }

    /**
     * @dev 交换方法
     * @param amount0Out 输出数额0
     * @param amount1Out 输出数额1
     * @param to    to地址
     * @param data  用于回调的数据
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        //确认amount0Out和amount1Out都大于0
        require(amount0Out > 0 || amount1Out > 0, 'GoSwap: INSUFFICIENT_OUTPUT_AMOUNT');
        //获取`储备量0`,`储备量1`
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //确认`输出数量0,1` < `储备量0,1`
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'GoSwap: INSUFFICIENT_LIQUIDITY');

        //初始化变量
        uint256 balance0;
        uint256 balance1;
        {
            //标记_token{0,1}的作用域，避免堆栈太深的错误
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = tokens[0];
            address _token1 = tokens[1];
            //确认to地址不等于_token0和_token1
            require(to != _token0 && to != _token1, 'GoSwap: INVALID_TO');
            //如果`输出数量0` > 0 安全发送`输出数量0`的token0到to地址
            if (amount0Out > 0) _safeTransfer(0, to, amount0Out); // optimistically transfer tokens
            //如果`输出数量1` > 0 安全发送`输出数量1`的token1到to地址
            if (amount1Out > 0) _safeTransfer(1, to, amount1Out); // optimistically transfer tokens
            //如果data的长度大于0 调用to地址的接口,闪电贷!
            if (data.length > 0) IGoSwapCallee(to).goswapCall(msg.sender, amount0Out, amount1Out, data);
            //调用交易钩子
            if (swapHookAddress != address(0))
                IGoSwapHook(swapHookAddress).swapHook(msg.sender, amount0Out, amount1Out, to);
            //获取当前合约在token0合约内的余额
            balance0 = balanceOfIndex(0);
            //获取当前合约在token1合约内的余额
            balance1 = balanceOfIndex(1);
        }
        //如果 余额0 > 储备0 - amount0Out 则 amount0In = 余额0 - (储备0 - amount0Out) 否则 amount0In = 0
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        //如果 余额1 > 储备1 - amount1Out 则 amount1In = 余额1 - (储备1 - amount1Out) 否则 amount1In = 0
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        //确认`输入数量0||1`大于0
        require(amount0In > 0 || amount1In > 0, 'GoSwap: INSUFFICIENT_INPUT_AMOUNT');
        {
            //标记reserve{0,1}的作用域，避免堆栈太深的错误
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            //调整后的余额0 = 余额0 * 1000 - (amount0In * fee)
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(fee));
            //调整后的余额1 = 余额1 * 1000 - (amount1In * fee)
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(fee));
            //确认balance0Adjusted * balance1Adjusted >= 储备0 * 储备1 * 1000000
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000**2),
                'GoSwap: K'
            );
        }

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //触发交换事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @dev 强制平衡以匹配储备
     * @param to to地址
     */
    function skim(address to) external lock {
        //将当前合约在`token0,1`的余额-`储备量0,1`安全发送到to地址
        _safeTransfer(0, to, balanceOfIndex(0).sub(reserves[0]));
        _safeTransfer(1, to, balanceOfIndex(1).sub(reserves[1]));
    }

    /**
     * @dev 强制准备金与余额匹配
     */
    function sync() external lock {
        _update(balanceOfIndex(0), balanceOfIndex(1), reserves[0], reserves[1]);
    }

    /**
     * @dev 按索引返回资产余额
     * @param tokenIndex token索引
     * @return balance 资产余额
     */
    function balanceOfIndex(uint8 tokenIndex) public view returns (uint256 balance) {
        // 资产余额 = 当前合约在token的余额 + 保险库中的存款数额 + 虚流动性
        balance = IERC20(tokens[tokenIndex]).balanceOf(address(this)).add(depositeds[tokenIndex]).add(
            dummys[tokenIndex]
        );
    }

    /**
     * @dev 向保险库批准最大值
     * @param tokenIndex token索引
     */
    function approveByIndex(uint8 tokenIndex) public onlyFeeToSetter {
        // 调用Token合约的approve方法向保险库合约批准最大值
        IERC20(tokens[tokenIndex]).approve(vaults[tokenIndex], uint256(-1));
    }

    /**
     * @dev 向保险库取消批准
     * @param tokenIndex token索引
     */
    function unApproveByIndex(uint8 tokenIndex) public onlyFeeToSetter {
        // 调用Token合约的approve方法将保险库合约的批准额设置为0
        IERC20(tokens[tokenIndex]).approve(vaults[tokenIndex], 0);
    }

    /**
     * @dev 向保险库取消批准
     * @param tokenIndex token索引
     * @param vault 保险库地址
     */
    function setVaults(uint8 tokenIndex, address vault) public onlyFeeToSetter {
        // 按照索引更新保险库合约地址
        vaults[tokenIndex] = vault;
        // 向保险库合约批准最大值
        approveByIndex(tokenIndex);
        // 触发事件
        emit VaultUpdated(tokenIndex, vault);
    }

    /**
     * @dev 向保险库存款
     * @param tokenIndex token索引
     * @param amount 存款数额
     */
    function _deposit(uint8 tokenIndex, uint256 amount) internal {
        // 确认存款数额大于0
        require(amount > 0, 'deposit amount must be greater than 0');
        // 更新存款数额
        depositeds[tokenIndex] = depositeds[tokenIndex].add(amount);
        // 向保险库合约存款
        IVault(vaults[tokenIndex]).deposit(amount);
        // 触发事件
        emit DepositedUpdated(depositeds[0], depositeds[1]);
    }

    /**
     * @dev 向保险库存款指定数额
     * @param tokenIndex token索引
     * @param amount 存款数额
     */
    function depositSome(uint8 tokenIndex, uint256 amount) external onlyFeeToSetter {
        // 向保险库存款指定数额
        _deposit(tokenIndex, amount);
    }

    /**
     * @dev 向保险库存款全部
     * @param tokenIndex token索引
     */
    function depositAll(uint8 tokenIndex) external onlyFeeToSetter {
        // 向保险库存款全部
        _deposit(tokenIndex, IERC20(tokens[tokenIndex]).balanceOf(address(this)));
    }

    /**
     * @dev 向保险库按存款比例存款
     * @param tokenIndex token索引
     */
    function _redeposit(uint8 tokenIndex) internal {
        // 存款数额 = 当前合约在token中的余额 * 存款比例 / 1000
        uint256 amount = IERC20(tokens[tokenIndex]).balanceOf(address(this)).mul(redepositRatios[tokenIndex]).div(1000);
        // 调用私有存款方法
        _deposit(tokenIndex, amount);
    }

    /**
     * @dev 设置存款比例
     * @param tokenIndex token索引
     * @param _redpositRatio token索引
     */
    function setRedepositRatio(uint8 tokenIndex, uint16 _redpositRatio) external onlyFeeToSetter {
        // 确认存款比例小于等于1000
        require(_redpositRatio <= 1000, 'ratio too large');
        // 按索引设置存款比例
        redepositRatios[tokenIndex] = _redpositRatio;
        // 触发事件
        emit RedepositRatioUpdated(tokenIndex, _redpositRatio);
    }

    /**
     * @dev 从保险库中取款
     * @param tokenIndex token索引
     * @param amount 存款数额
     */
    function _withdraw(uint8 tokenIndex, uint256 amount) internal {
        // 确认取款数额大于0
        require(amount > 0, 'withdraw amount must be greater than 0');
        // 计算当前合约在token合约中的余额
        uint256 before = IERC20(tokens[tokenIndex]).balanceOf(address(this));
        // 从保险库中取款amount数额
        IVault(vaults[tokenIndex]).withdraw(amount);
        // 计算取款之后成功取出的数额
        uint256 received = IERC20(tokens[tokenIndex]).balanceOf(address(this)).sub(before);
        // 如果收到的数额<=存款数额
        if (received <= depositeds[tokenIndex]) {
            // 在存款数额中减去收到的数额
            depositeds[tokenIndex] -= received;
        } else {
            // 奖励等于多出来的取款,用收到的数额减去存款数额
            uint256 reward = received.sub(depositeds[tokenIndex]);
            // 将存款数额归零
            depositeds[tokenIndex] = 0;
            // 将奖励发送给feeTo
            _safeTransfer(tokenIndex, getFeeTo(), reward);
        }

        emit DepositedUpdated(depositeds[0], depositeds[1]);
    }

    /**
     * @dev 从保险库中取款全部
     * @param tokenIndex token索引
     */
    function _withdrawAll(uint8 tokenIndex) internal {
        // 将当前合约在tokens[tokenIndex]的余额全部取出
        _withdraw(tokenIndex, IERC20(vaults[tokenIndex]).balanceOf(address(this)));
    }

    /**
     * @dev 从保险库中取款
     * @param tokenIndex token索引
     * @param amount 存款数额
     */
    function withdraw(uint8 tokenIndex, uint256 amount) external onlyFeeToSetter {
        _withdraw(tokenIndex, amount);
    }

    /**
     * @dev 从保险库中取款全部
     * @param tokenIndex token索引
     */
    function withdrawAll(uint8 tokenIndex) external onlyFeeToSetter {
        _withdrawAll(tokenIndex);
    }
}
