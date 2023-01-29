import { ConfigService } from '@nestjs/config';
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import {
  L1SentMessageEvents,
  L1ToL2,
  L2RelayedMessageEvents,
  L2SentMessageEvents,
  L2ToL1,
} from 'src/typeorm';
import { EntityManager, getConnection, getManager, Repository } from 'typeorm';
import Web3 from 'web3';
import ABI from '../abi/L2CrossDomainMessenger.json';
import { utils } from 'ethers';

@Injectable()
export class L2IngestionService {
  private readonly logger = new Logger(L2IngestionService.name);
  entityManager: EntityManager;
  web3: Web3;
  crossDomainMessengerContract: any;
  constructor(
    private configService: ConfigService,
    @InjectRepository(L2RelayedMessageEvents)
    private readonly relayedEventsRepository: Repository<L2RelayedMessageEvents>,
    @InjectRepository(L2SentMessageEvents)
    private readonly sentEventsRepository: Repository<L2SentMessageEvents>,
  ) {
    this.entityManager = getManager();
    const web3 = new Web3(
      new Web3.providers.HttpProvider(configService.get('L2_RPC')),
    );
    this.crossDomainMessengerContract = new web3.eth.Contract(
      ABI as any,
      configService.get('L2_CROSS_DOMAIN_MESSENGER_ADDRESS'),
    );
    this.web3 = web3;
    // this.sync();
  }
  async getSentMessageByBlockNumber(fromBlock: number, toBlock: number) {
    return this.crossDomainMessengerContract.getPastEvents('SentMessage', {
      fromBlock,
      toBlock,
    });
  }
  async getRelayedMessageByBlockNumber(fromBlock: number, toBlock: number) {
    return this.crossDomainMessengerContract.getPastEvents('RelayedMessage', {
      fromBlock,
      toBlock,
    });
  }
  verifyDomainCalldataHash({ target, sender, message, messageNonce }): string {
    const xDomainCalldata = this.web3.eth.abi.encodeFunctionCall(
      {
        name: 'relayMessage',
        type: 'function',
        inputs: [
          { type: 'address', name: 'target' },
          { type: 'address', name: 'sender' },
          { type: 'bytes', name: 'message' },
          { type: 'uint256', name: 'messageNonce' },
        ],
      },
      [target, sender, message, messageNonce],
    );
    return Web3.utils.keccak256(xDomainCalldata);
  }
  async getCurrentBlockNumber(): Promise<number> {
    return this.web3.eth.getBlockNumber();
  }
  async getSentEventsBlockNumber(): Promise<number> {
    const result = await this.sentEventsRepository
      .createQueryBuilder()
      .select('Max(block_number)', 'blockNumber')
      .getRawOne();
    return Number(result.blockNumber) || 0;
  }
  async getRelayedEventsBlockNumber(): Promise<number> {
    const result = await this.relayedEventsRepository
      .createQueryBuilder()
      .select('Max(block_number)', 'blockNumber')
      .getRawOne();
    return Number(result.blockNumber) || 0;
  }
  async createSentEvents(startBlock, endBlock) {
    const list = await this.getSentMessageByBlockNumber(startBlock, endBlock);
    const result: any[] = [];
    const iface = new utils.Interface([
      'function finalizeETHWithdrawal(address _from, address _to, uint256 _amount, bytes calldata _data)',
      'function finalizeBitWithdrawal(address _from, address _to, uint256 _amount, bytes calldata _data)',
      'function finalizeERC20Withdrawal(address _l1Token, address _l2Token, address _from, address _to, uint256 _amount, bytes calldata _data)',
    ]);
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: { target, sender, message, messageNonce, gasLimit },
        signature,
      } = item;
      const funName = message.slice(0, 10);
      let name = '';
      let symbol = '';
      let l1_token = '0x0000000000000000000000000000000000000000';
      let l2_token = '0x0000000000000000000000000000000000000000';
      let from = '0x0000000000000000000000000000000000000000';
      let to = '0x0000000000000000000000000000000000000000';
      let value = '0';
      if (funName === '0x1532ec34') {
        const decodeMsg = iface.decodeFunctionData(
          'finalizeETHWithdrawal',
          message,
        );
        name = 'ETH';
        symbol = 'ETH';
        from = decodeMsg._from;
        to = decodeMsg._to;
        value = this.web3.utils.hexToNumberString(decodeMsg._amount._hex);
        this.logger.log(
          `finalizeETHWithdrawal: from: [${from}], to: [${to}], value: [${value}]`,
        );
      }
      if (funName === '0xa9f9e675') {
        const decodeMsg = iface.decodeFunctionData(
          'finalizeERC20Withdrawal',
          message,
        );
        name = 'ERC20';
        symbol = 'ERC20';
        l1_token = decodeMsg._l1Token;
        l2_token = decodeMsg._l2Token;
        from = decodeMsg._from;
        to = decodeMsg._to;
        value = this.web3.utils.hexToNumberString(decodeMsg._amount._hex);
        this.logger.log(
          `finalizeERC20Withdrawal: l1_token: [${l1_token}], l2_token: [${l2_token}], from: [${from}], to: [${to}], value: [${value}]`,
        );
      }
      if (funName === '0x839f0ec6') {
        const decodeMsg = iface.decodeFunctionData(
          'finalizeBitWithdrawal',
          message,
        );
        name = 'BIT';
        symbol = 'BIT';
        from = decodeMsg._from;
        to = decodeMsg._to;
        value = this.web3.utils.hexToNumberString(decodeMsg._amount._hex);
        this.logger.log(
          `finalizeBitWithdrawal: from: [${from}], to: [${to}], value: [${value}]`,
        );
      }
      const { timestamp } = await this.web3.eth.getBlock(blockNumber);
      try {
        await queryRunner.startTransaction();
        const savedResult = await queryRunner.manager.save(
          L2SentMessageEvents,
          {
            tx_hash: transactionHash,
            block_number: blockNumber.toString(),
            target,
            sender,
            message,
            message_nonce: messageNonce,
            gas_limit: gasLimit,
            signature,
            timestamp: new Date(Number(timestamp) * 1000).toISOString(),
            name: name,
            symbol: symbol,
            l1_token: l1_token,
            l2_token: l2_token,
            from: from,
            to: to,
            value: value,
            inserted_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          },
        );
        const msgHash = this.verifyDomainCalldataHash({
          target: target.toString(),
          sender: sender.toString(),
          message: message.toString(),
          messageNonce: messageNonce.toString(),
        });
        await queryRunner.manager.save(L2ToL1, {
          hash: null,
          l2_hash: transactionHash,
          msg_hash: msgHash,
          block: blockNumber,
          msg_nonce: Number(messageNonce),
          from_address: target,
          txn_batch_index: Number(messageNonce),
          state_batch_index: Number(messageNonce),
          timestamp: new Date(Number(timestamp) * 1000).toISOString(),
          status: 'Waiting',
          gas_limit: gasLimit,
          l1_token: l1_token,
          l2_token: l2_token,
          from: from,
          to: to,
          value: value,
          inserted_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        });
        result.push(savedResult);
        this.logger.log(
          `l2 createSentEvents success:${JSON.stringify(savedResult)}`,
        );
        await queryRunner.commitTransaction();
      } catch (error) {
        this.logger.error(
          `l2 createSentEvents blocknumber:${blockNumber} ${error}`,
        );
        await queryRunner.rollbackTransaction();
      }
    }
    await queryRunner.release();
    return result;
  }
  async createRelayedEvents(startBlock, endBlock) {
    const list = await this.getRelayedMessageByBlockNumber(
      startBlock,
      endBlock,
    );
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    const result: any = [];
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: { msgHash },
        signature,
      } = item;
      const { timestamp } = await this.web3.eth.getBlock(blockNumber);
      try {
        await queryRunner.startTransaction();
        const savedResult = await queryRunner.manager.save(
          L2RelayedMessageEvents,
          {
            tx_hash: transactionHash,
            block_number: blockNumber.toString(),
            msg_hash: msgHash,
            signature,
            timestamp: new Date(Number(timestamp) * 1000).toISOString(),
            inserted_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          },
        );
        result.push(savedResult);
        this.logger.log(
          `l2 createRelayedEvents success:${JSON.stringify(savedResult)}`,
        );
        await queryRunner.commitTransaction();
      } catch (error) {
        this.logger.error(
          `l2 createRelayedEvents blocknumber:${blockNumber} ${error}`,
        );
        await queryRunner.rollbackTransaction();
      }
    }
    await queryRunner.release();
    return result;
  }
  async syncSentEvents() {
    const startBlockNumber = await this.getSentEventsBlockNumber();
    const currentBlockNumber = await this.getCurrentBlockNumber();
    for (let i = startBlockNumber; i < currentBlockNumber; i += 1) {
      const start = i === 0 ? 0 : i + 1;
      const end = Math.min(i + 1, currentBlockNumber);
      const result = await this.createSentEvents(start, end);
      this.logger.log(
        `sync [${result.length}] l2_sent_message_events from block [${start}] to [${end}]`,
      );
    }
  }
  async syncRelayedEvents() {
    const startBlockNumber = await this.getRelayedEventsBlockNumber();
    const currentBlockNumber = await this.getCurrentBlockNumber();
    for (let i = startBlockNumber; i < currentBlockNumber; i += 1) {
      const start = i === 0 ? 0 : i + 1;
      const end = Math.min(i + 1, currentBlockNumber);
      const result = await this.createRelayedEvents(start, end);
      this.logger.log(
        `sync [${result.length}] l2_relayed_message_events from block [${start}] to [${end}]`,
      );
    }
  }
  async sync() {
    this.syncSentEvents();
    this.syncRelayedEvents();
  }
  async getAllSentEvents() {
    return this.sentEventsRepository.find();
  }
  async getUnMergeSentEvents() {
    return this.sentEventsRepository.find({ where: { is_merge: false } });
  }
  async getAllRelayedEvents() {
    return this.relayedEventsRepository.find();
  }
  async getRelayedEventByMsgHash(msgHash: string) {
    return this.relayedEventsRepository.findOne({
      where: { msg_hash: msgHash },
    });
  }
  async getRelayedEventByIsMerge(is_merge: boolean) {
    return this.relayedEventsRepository.find({
      where: { is_merge: is_merge },
    });
  }
  async getRelayedEventByTxHash(txHash: string) {
    return this.relayedEventsRepository.findOne({
      where: { tx_hash: txHash },
    });
  }
  async getSentEventByTxHash(txHash: string) {
    return this.sentEventsRepository.findOne({
      where: { tx_hash: txHash },
    });
  }
}
