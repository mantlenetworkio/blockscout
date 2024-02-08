import { ConfigService } from '@nestjs/config';
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import {
  L2ToL1,
  L1ToL2,
  Transactions,
} from 'src/typeorm';
import { EntityManager, getConnection, getManager, Repository, Not, IsNull } from 'typeorm';
import ABI from '../abi/ERC20.json';
import { Gauge } from "prom-client";
import { InjectMetric } from "@willsoto/nestjs-prometheus";
import { PublicClient, createPublicClient, http } from 'viem'
import { utils, constants, BigNumberish } from 'ethers';

@Injectable()
export class MonitorService {
  private readonly logger = new Logger(MonitorService.name);
  entityManager: EntityManager;
  l1Client: PublicClient;
  l2Client: PublicClient;
  crossDomainMessengerContract: any;
  constructor(
    private configService: ConfigService,
    @InjectRepository(L2ToL1)
    private readonly l2ToL1Repository: Repository<L2ToL1>,
    @InjectRepository(L1ToL2)
    private readonly l1ToL2Repository: Repository<L1ToL2>,
    @InjectRepository(Transactions)
    private readonly transactionsRepository: Repository<Transactions>,
    @InjectMetric('block_number')
    public metricBlockNumber: Gauge<string>,
    @InjectMetric('miss_block_number')
    public metricMissBlockNumber: Gauge<string>,
    // MNT
    @InjectMetric('mnt_total_locked_value')
    public metricMntTotalLockedValue: Gauge<string>,
    @InjectMetric('mnt_total_deposit_value')
    public metricMntTotalDepositValue: Gauge<string>,
    @InjectMetric('mnt_total_withdraw_value')
    public metricMntTotalWithdrawValue: Gauge<string>,
    // ETH
    @InjectMetric('eth_total_locked_value')
    public metricEthTotalLockedValue: Gauge<string>,
    @InjectMetric('eth_total_deposit_value')
    public metricEthTotalDepositValue: Gauge<string>,
    @InjectMetric('eth_total_withdraw_value')
    public metricEthTotalWithdrawValue: Gauge<string>,
    // USDT
    @InjectMetric('usdt_total_locked_value')
    public metricUSDTTotalLockedValue: Gauge<string>,
    @InjectMetric('usdt_total_deposit_value')
    public metricUSDTTotalDepositValue: Gauge<string>,
    @InjectMetric('usdt_total_withdraw_value')
    public metricUSDTTotalWithdrawValue: Gauge<string>,
    // USDC
    @InjectMetric('usdc_total_locked_value')
    public metricUSDCTotalLockedValue: Gauge<string>,
    @InjectMetric('usdc_total_deposit_value')
    public metricUSDCTotalDepositValue: Gauge<string>,
    @InjectMetric('usdc_total_withdraw_value')
    public metricUSDCTotalWithdrawValue: Gauge<string>,
    // LUSD
    @InjectMetric('lusd_total_locked_value')
    public metricLUSDTotalLockedValue: Gauge<string>,
    @InjectMetric('lusd_total_deposit_value')
    public metricLUSDTotalDepositValue: Gauge<string>,
    @InjectMetric('lusd_total_withdraw_value')
    public metricLUSDTotalWithdrawValue: Gauge<string>,
  ) {
    this.entityManager = getManager();

    const l1Client = createPublicClient({
      transport: http(configService.get('L1_RPC'))
    })
    this.l1Client = l1Client;

    const l2Client = createPublicClient({
      transport: http(configService.get('L2_RPC'))
    })
    this.l2Client = l2Client;
  }
  async getL1BalanceOf(token, address): Promise<any> {
    return await this.l1Client.readContract({
      address: token,
      abi: ABI,
      functionName: 'balanceOf',
      args: [address]
    })
  }
  async getL2BalanceOf(address) {
    const balance = await this.l2Client.readContract({
      address: this.configService.get('L2MNT'),
      abi: ABI,
      functionName: 'balanceOf',
      args: [address]
    })
    return balance;
  }
  // ETH l1_token address: 0x0000000000000000000000000000000000000000
  // ETH l2_token address: 0xdEAddEaDdeadDEadDEADDEAddEADDEAddead1111
  // MNT l2_token address: 0xdeaddeaddeaddeaddeaddeaddeaddeaddead0000
  async syncBridgeData() {
    try {
      const l1_bridge = this.configService.get('Proxy__BVM_L1StandardBridge')
      /* ---------MNT--------- */
      const L2_MNT = '0xdeaddeaddeaddeaddeaddeaddeaddeaddead0000'
      const mntLockedBalance = await this.getL1BalanceOf(this.configService.get('Proxy__L1MNT'), l1_bridge)
      const mntTotalDeposit = await this.getTotalDepositValueByL2Token(L2_MNT);
      const mntTotalWithdraw = await this.getTotalWithdrawValueByL2Token(L2_MNT)
      this.metricMntTotalLockedValue.set(Number(utils.formatEther(mntLockedBalance || 0)))
      this.metricMntTotalDepositValue.set(Number(utils.formatEther(mntTotalDeposit || 0)))
      this.metricMntTotalWithdrawValue.set(Number(utils.formatEther(mntTotalWithdraw || 0)))
      /* ---------ETH--------- */
      const L1_ETH = constants.AddressZero
      const ethLockedBalance = await this.l1Client.getBalance({ address: this.configService.get('Proxy__BVM_L1StandardBridge') });
      const ethTotalDeposit = await this.getTotalDepositValueByL1Token(L1_ETH);
      const ethTotalWithdraw = await this.getTotalWithdrawValueByL1Token(L1_ETH);
      this.metricEthTotalLockedValue.set(Number(utils.formatEther(ethLockedBalance || 0)))
      this.metricEthTotalDepositValue.set(Number(utils.formatEther(ethTotalDeposit || 0)))
      this.metricEthTotalWithdrawValue.set(Number(utils.formatEther(ethTotalWithdraw || 0)))
      /* ---------USDT--------- */
      const l1_usdt = this.configService.get('L1_USDT_ADDRESS')
      if(l1_usdt){
        const usdtLockedBalance = await this.getL1BalanceOf(l1_usdt, l1_bridge)
        const usdtTotalDeposit = await this.getTotalDepositValueByL1Token(l1_usdt);
        const usdtTotalWithdraw = await this.getTotalWithdrawValueByL1Token(l1_usdt);
        this.metricUSDTTotalLockedValue.set(Number(utils.formatEther(usdtLockedBalance || 0)))
        this.metricUSDTTotalDepositValue.set(Number(utils.formatEther(usdtTotalDeposit || 0)))
        this.metricUSDTTotalWithdrawValue.set(Number(utils.formatEther(usdtTotalWithdraw || 0)))
      }
      /* ---------USDC--------- */
      const l1_usdc = this.configService.get('L1_USDC_ADDRESS')
      if(l1_usdc){
        const usdcLockedBalance = await this.getL1BalanceOf(l1_usdc, l1_bridge)
        const usdcTotalDeposit = await this.getTotalDepositValueByL1Token(l1_usdc);
        const usdcTotalWithdraw = await this.getTotalWithdrawValueByL1Token(l1_usdc);
        this.metricUSDCTotalLockedValue.set(Number(utils.formatEther(usdcLockedBalance || 0)))
        this.metricUSDCTotalDepositValue.set(Number(utils.formatEther(usdcTotalDeposit || 0)))
        this.metricUSDCTotalWithdrawValue.set(Number(utils.formatEther(usdcTotalWithdraw || 0)))
      }
      /* ---------LUSD--------- */
      const l1_lusd = this.configService.get('L1_LUSD_ADDRESS')
      if(l1_lusd){
        const lusdLockedBalance = await this.getL1BalanceOf(l1_lusd, l1_bridge)
        const lusdTotalDeposit = await this.getTotalDepositValueByL1Token(l1_lusd);
        const lusdTotalWithdraw = await this.getTotalWithdrawValueByL1Token(l1_lusd);
        this.metricLUSDTotalLockedValue.set(Number(utils.formatEther(lusdLockedBalance || 0)))
        this.metricLUSDTotalDepositValue.set(Number(utils.formatEther(lusdTotalDeposit || 0)))
        this.metricLUSDTotalWithdrawValue.set(Number(utils.formatEther(lusdTotalWithdraw || 0)))
      }
    } catch (error) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `sync bridge data error: ${error}`
      })
    }
  }
  async getTotalDepositValueByL1Token(tokenAddress) {
    const [ result ] = await this.entityManager.query(`
      SELECT SUM(value) as total_value FROM l1_to_l2 WHERE type = 1 AND (l1_token = $1 OR l1_token = $2);
    `, [tokenAddress, utils.getAddress(tokenAddress)])
    return result.total_value;
  }
  async getTotalDepositValueByL2Token(tokenAddress) {
    const [ result ] = await this.entityManager.query(`
      SELECT SUM(value) as total_value FROM l1_to_l2 WHERE type = 1 AND (l2_token = $1 OR l2_token = $2);
    `, [tokenAddress, utils.getAddress(tokenAddress)])
    return result.total_value;
  }
  async getTotalWithdrawValueByL1Token(tokenAddress) {
    const [ result ]  = await this.entityManager.query(`
      SELECT SUM(value) as total_value FROM l2_to_l1 WHERE l1_token = $1 OR l1_token = $2;
    `, [tokenAddress, utils.getAddress(tokenAddress)])
    return result.total_value;
  }
  async getTotalWithdrawValueByL2Token(tokenAddress) {
    const [ result ]  = await this.entityManager.query(`
      SELECT SUM(value) as total_value FROM l2_to_l1 WHERE l2_token = $1 OR l2_token = $2;
    `, [tokenAddress, utils.getAddress(tokenAddress)])
    return result.total_value;
  }
  async getLatestBlockNumber() {
    const { block_number } = await this.transactionsRepository.findOne({
      select: [ 'block_number' ],
      where: { block_number: Not(IsNull())},
      order: { block_number: 'DESC' },
    })
    return block_number;
  }
  async missBlockNumber() {
    try {
      const blockNumber = await this.getLatestBlockNumber();
      this.metricBlockNumber.set(blockNumber);
      if (blockNumber < 2000) return;
      const endBlock = blockNumber - 1000;
      const startBlock = endBlock - 1000;
      const [ result ] = await this.entityManager.query(`
        SELECT COUNT(*) FROM transactions WHERE block_number >= $1 AND block_number < $2;
      `, [startBlock, endBlock])
      this.metricMissBlockNumber.set(Number(result.count));
      return result.count;
    } catch (error) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `miss BlockNumber error: ${error?.message}`
      })
    }
  }
}
