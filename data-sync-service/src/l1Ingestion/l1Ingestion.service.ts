import { ConfigService } from '@nestjs/config';
import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import {
  L1RelayedMessageEvents,
  L1SentMessageEvents,
  L1ToL2,
  L2RelayedMessageEvents,
  L2SentMessageEvents,
  L2ToL1,
  StateBatches,
  TxnBatches,
  Transactions,
  Tokens,
  DaBatches,
  DaBatchTransactions,
} from 'src/typeorm';
import {
  EntityManager,
  getConnection,
  getManager,
  Repository,
  IsNull,
  Not,
  In,
} from 'typeorm';
import Web3 from 'web3';
import CMGABI from '../abi/L1CrossDomainMessenger.json';
import CTCABI from '../abi/CanonicalTransactionChain.json';
import SCCABI from '../abi/StateCommitmentChain.json';
import DAABI from '../abi/BVM_EigenDataLayrChain.json';
import { L2IngestionService } from '../l2Ingestion/l2Ingestion.service';
import { EigenlayerService } from '../grpc/eigenlayer.service';
import { utils } from 'ethers';
import { from } from 'rxjs';
const FraudProofWindow = 0;
let l1l2MergerIsProcessing = false;
import { decode, encode } from 'rlp';



@Injectable()
export class L1IngestionService {
  private readonly logger = new Logger(L1IngestionService.name);
  entityManager: EntityManager;
  web3: Web3;
  ctcContract: any;
  sccContract: any;
  crossDomainMessengerContract: any;
  bvmEigenDataLayrChain: any;
  constructor(
    private configService: ConfigService,
    @InjectRepository(L1RelayedMessageEvents)
    private readonly relayedEventsRepository: Repository<L1RelayedMessageEvents>,
    @InjectRepository(L1SentMessageEvents)
    private readonly sentEventsRepository: Repository<L1SentMessageEvents>,
    @InjectRepository(StateBatches)
    private readonly stateBatchesRepository: Repository<StateBatches>,
    @InjectRepository(TxnBatches)
    private readonly txnBatchesRepository: Repository<TxnBatches>,
    @InjectRepository(L2ToL1)
    private readonly txnL2ToL1Repository: Repository<L2ToL1>,
    @InjectRepository(L1ToL2)
    private readonly txnL1ToL2Repository: Repository<L1ToL2>,
    @InjectRepository(Transactions)
    private readonly transactions: Repository<Transactions>,
    @InjectRepository(Tokens)
    private readonly tokensRepository: Repository<Tokens>,
    @InjectRepository(DaBatches)
    private readonly daBatchesRepository: Repository<DaBatches>,
    @InjectRepository(DaBatchTransactions)
    private readonly DaBatchTransactionsRepository: Repository<DaBatchTransactions>,
    private readonly l2IngestionService: L2IngestionService,
    private readonly eigenlayerService: EigenlayerService,
  ) {
    this.entityManager = getManager();
    const web3 = new Web3(
      new Web3.providers.HttpProvider(configService.get('L1_RPC')),
    );
    const crossDomainMessengerContract = new web3.eth.Contract(
      CMGABI as any,
      configService.get('L1_CROSS_DOMAIN_MESSENGER_ADDRESS'),
    );
    const ctcContract = new web3.eth.Contract(
      CTCABI as any,
      configService.get('CTC_ADDRESS'),
    );
    const sccContract = new web3.eth.Contract(
      SCCABI as any,
      configService.get('SCC_ADDRESS'),
    );
    const bvmEigenDataLayrChain = new web3.eth.Contract(
      DAABI as any,
      configService.get('DA_ADDRESS'),
    );
    this.ctcContract = ctcContract;
    this.sccContract = sccContract;
    this.crossDomainMessengerContract = crossDomainMessengerContract;
    this.bvmEigenDataLayrChain = bvmEigenDataLayrChain;
    this.web3 = web3;
  }
  async getCtcTransactionBatchAppendedByBlockNumber(
    fromBlock: number,
    toBlock: number,
  ) {
    return this.ctcContract.getPastEvents('TransactionBatchAppended', {
      fromBlock,
      toBlock,
    });
  }
  async getSccStateBatchAppendedByBlockNumber(
    fromBlock: number,
    toBlock: number,
  ) {
    return this.sccContract.getPastEvents('StateBatchAppended', {
      fromBlock,
      toBlock,
    });
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
  async getLatestBatchIndex() {
    return this.bvmEigenDataLayrChain.methods.rollupBatchIndex().call();
  }
  async getRollupInfoByBatchIndex(batch_index) {
    return this.bvmEigenDataLayrChain.methods
      .getRollupStoreByRollupBatchIndex(batch_index)
      .call();
  }
  async getSccTotalElements() {
    return this.sccContract.methods.getTotalElements().call();
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
  async getTxnBatchBlockNumber(): Promise<number> {
    const result = await this.txnBatchesRepository
      .createQueryBuilder()
      .select('Max(block_number)', 'blockNumber')
      .getRawOne();
    return Number(result.blockNumber) || 0;
  }
  async getStateBatchBlockNumber(): Promise<number> {
    const result = await this.stateBatchesRepository
      .createQueryBuilder()
      .select('Max(block_number)', 'blockNumber')
      .getRawOne();
    return Number(result.blockNumber) || 0;
  }
  async getUnMergeSentEvents() {
    return this.sentEventsRepository.find({ where: { is_merge: false } });
  }
  async getL2toL1WaitTx(status) {
    return this.txnL2ToL1Repository.find({ where: { status: status } });
  }
  async createTxnBatchesEvents(startBlock, endBlock) {
    const list = await this.getCtcTransactionBatchAppendedByBlockNumber(
      startBlock,
      endBlock,
    );
    const txnBatchesInsertData: any[] = []
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: {
          _batchIndex,
          _batchRoot,
          _batchSize,
          _prevTotalElements,
          _signature,
          _extraData,
        },
      } = item;
      const { timestamp } = await this.web3.eth.getBlock(blockNumber);
      txnBatchesInsertData.push({
        batch_index: _batchIndex,
        block_number: blockNumber.toString(),
        hash: transactionHash,
        size: _batchSize,
        l1_block_number: blockNumber,
        batch_root: _batchRoot,
        extra_data: _extraData,
        pre_total_elements: _prevTotalElements,
        timestamp: new Date(Number(timestamp) * 1000).toISOString(),
        inserted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
    }
    const result: any[] = [];
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    try {
      await queryRunner.startTransaction();
      const savedResult = await queryRunner.manager.insert(TxnBatches, txnBatchesInsertData);
      result.push(savedResult);
      await queryRunner.commitTransaction();
    } catch (error) {
      this.logger.error(
        `l1 createTxnBatchesEvents ${error}`,
      );
      await queryRunner.rollbackTransaction();
    }
    await queryRunner.release();
    return result;
  }
  async createStateBatchesEvents(startBlock, endBlock) {
    const list = await this.getSccStateBatchAppendedByBlockNumber(
      startBlock,
      endBlock,
    );
    const stateBatchesInsertData: any[] = [];
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: {
          _batchIndex,
          _batchRoot,
          _batchSize,
          _prevTotalElements,
          _extraData,
        },
      } = item;
      const { timestamp } = await this.web3.eth.getBlock(blockNumber);
      stateBatchesInsertData.push({
        batch_index: _batchIndex,
        block_number: blockNumber.toString(),
        hash: transactionHash,
        size: _batchSize,
        l1_block_number: blockNumber,
        batch_root: _batchRoot,
        extra_data: _extraData,
        pre_total_elements: _prevTotalElements,
        timestamp: new Date(Number(timestamp) * 1000).toISOString(),
        inserted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
    }
    const result: any[] = [];
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    try {
      await queryRunner.startTransaction();
      const savedResult = await queryRunner.manager.insert(StateBatches, stateBatchesInsertData);
      result.push(savedResult);
      await queryRunner.commitTransaction();
    } catch (error) {
      this.logger.error(
        `l1 createStateBatchesEvents ${error}`,
      );
      await queryRunner.rollbackTransaction();
    }
    await queryRunner.release();
    return result;
  }
  async createSentEvents(startBlock, endBlock) {
    const list = await this.getSentMessageByBlockNumber(startBlock, endBlock);
    const result: any[] = [];
    const iface = new utils.Interface([
      'function claimReward(uint256 _blockStartHeight, uint32 _length, uint256 _batchTime, address[] calldata _tssMembers)',
      'function finalizeDeposit(address _l1Token, address _l2Token, address _from, address _to, uint256 _amount, bytes calldata _data)',
    ]);
    let l1_token = '0x0000000000000000000000000000000000000000';
    let l2_token = '0x0000000000000000000000000000000000000000';
    let from = '0x0000000000000000000000000000000000000000';
    let to = '0x0000000000000000000000000000000000000000';
    let value = '0';
    let type = 0;
    const l1SentMessageEventsInsertData: any[] = [];
    const l1ToL2InsertData: any[] = [];
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: { target, sender, message, messageNonce, gasLimit },
        signature,
      } = item;
      const funName = message.slice(0, 10);
      if (funName === '0x662a633a') {
        const decodeMsg = iface.decodeFunctionData('finalizeDeposit', message);
        l1_token = decodeMsg._l1Token;
        l2_token = decodeMsg._l2Token;
        from = decodeMsg._from;
        to = decodeMsg._to;
        value = this.web3.utils.hexToNumberString(decodeMsg._amount._hex);
        type = 1; // user deposit
        this.logger.log(
          `l1_token: [${l1_token}], l2_token: [${l2_token}], from: [${from}], to: [${to}], value: [${value}]`,
        );
      } else if (funName === '0x0fae75d9') {
        const decodeMsg = iface.decodeFunctionData('claimReward', message);
        type = 0; // reward
        this.logger.log(`reward tssMembers is [${decodeMsg._tssMembers}]`);
      }
      const { timestamp } = await this.web3.eth.getBlock(blockNumber);
      const msgHash = this.verifyDomainCalldataHash({
        target: target.toString(),
        sender: sender.toString(),
        message: message.toString(),
        messageNonce: messageNonce.toString(),
      });
      l1SentMessageEventsInsertData.push({
        tx_hash: transactionHash,
        block_number: blockNumber.toString(),
        target,
        sender,
        message,
        message_nonce: messageNonce,
        gas_limit: gasLimit,
        signature,
        l1_token: l1_token,
        l2_token: l2_token,
        from: from,
        to: to,
        value: value,
        type: type,
        inserted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      l1ToL2InsertData.push({
        hash: transactionHash,
        l2_hash: null,
        msg_hash: msgHash,
        block: blockNumber,
        timestamp: new Date(Number(timestamp) * 1000).toISOString(),
        tx_origin: sender,
        queue_index: Number(messageNonce),
        target: sender,
        gas_limit: gasLimit,
        status: 'Ready for Relay',
        l1_token: l1_token,
        l2_token: l2_token,
        from: from,
        to: to,
        value: value,
        type: type,
        inserted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
    }
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    try {
      await queryRunner.startTransaction();
      const savedResult = await queryRunner.manager.insert(
        L1SentMessageEvents,
        l1SentMessageEventsInsertData,
      );
      await queryRunner.manager.insert(L1ToL2, l1ToL2InsertData);
      result.push(savedResult);
      await queryRunner.commitTransaction();
    } catch (error) {
      this.logger.error(
        `l1 createSentEvents ${error}`,
      );
      await queryRunner.rollbackTransaction();
    }
    await queryRunner.release();
    return result;
  }
  async createRelayedEvents(startBlock, endBlock) {
    const list = await this.getRelayedMessageByBlockNumber(
      startBlock,
      endBlock,
    );
    const result: any = [];
    const l1RelayedMessageEventsInsertData: any[] = [];
    for (const item of list) {
      const {
        blockNumber,
        transactionHash,
        returnValues: { msgHash },
        signature,
      } = item;
      l1RelayedMessageEventsInsertData.push({
        tx_hash: transactionHash,
        block_number: blockNumber.toString(),
        msg_hash: msgHash,
        signature,
        inserted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      
    }
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    try {
      await queryRunner.startTransaction();
      const savedResult = await queryRunner.manager.insert(
        L1RelayedMessageEvents,
        l1RelayedMessageEventsInsertData,
      );
      result.push(savedResult);
      await queryRunner.commitTransaction();
    } catch (error) {
      this.logger.error(
        `l1 createRelayedEvents ${error}`,
      );
      await queryRunner.rollbackTransaction();
    }
    await queryRunner.release();
    return result;
  }
  async createL1L2Relation() {
    if (!l1l2MergerIsProcessing) {
      const unMergeTxList =
        await this.l2IngestionService.getRelayedEventByIsMerge(false);
      this.logger.log(`start create l1->l2 relation`);
      const l1ToL2UpdateList = []
      const l1SentMessageEventsTxHashList = []
      const l2RelayedMessageEventsTxHashList = []
      for (let i = 0; i < unMergeTxList.length; i++) {
        const l1ToL2Transaction = await this.getL1ToL2TxByMsgHash(
          unMergeTxList[i].msg_hash,
        );
        if (l1ToL2Transaction) {
          let tx_type = 1;
          if (l1ToL2Transaction.type === 0) {
            tx_type = 3;
          }
          l1ToL2UpdateList.push({
            l2_hash: unMergeTxList[i].tx_hash,
            status: 'Relayed',
            hash: l1ToL2Transaction.hash
          })
          l1SentMessageEventsTxHashList.push(l1ToL2Transaction.hash)
          l2RelayedMessageEventsTxHashList.push(unMergeTxList[i].tx_hash)
        }
      }
      const dataSource = getConnection();
      const queryRunner = dataSource.createQueryRunner();
      await queryRunner.connect();
      await queryRunner.startTransaction();
      try {
        await queryRunner.manager
          .createQueryBuilder()
          .setLock('pessimistic_write')
          .insert()
          .into(L1ToL2)
          .values(l1ToL2UpdateList)
          .orUpdate(["l2_hash", "status"], ["hash"], {
            skipUpdateIfNoValuesChanged: true
          })
          .execute();
        await queryRunner.manager
          .createQueryBuilder()
          .setLock('pessimistic_write')
          .update(L1SentMessageEvents)
          .set({ is_merge: true })
          .where({ tx_hash: In(l1SentMessageEventsTxHashList) })
          .execute();
        await queryRunner.manager
          .createQueryBuilder()
          .setLock('pessimistic_write')
          .update(L2RelayedMessageEvents)
          .set({ is_merge: true })
          .where({ tx_hash: In(l2RelayedMessageEventsTxHashList) })
          .execute();
        // await queryRunner.manager.query(
        //   `UPDATE transactions SET l1_origin_tx_hash=$1, l1l2_type=$2 WHERE hash=$3;`,
        //   [unMergeTxList[i].tx_hash, tx_type, l1ToL2Transaction.l2_hash],
        // );
        await queryRunner.commitTransaction();
        this.logger.log(`commit l1->l2 data successes`);
      } catch (error) {
        this.logger.error(
          `create l1->l2 relation to l1_to_l2 table error ${error}`,
        );
        await queryRunner.rollbackTransaction();
      } finally {
        await queryRunner.release();
        this.logger.log(`create l1->l2 relation to l1_to_l2 table finish`);
      }
      l1l2MergerIsProcessing = false;
    } else {
      this.logger.log(
        `this task is in processing and l1l2MergerIsProcessing is ${l1l2MergerIsProcessing}`,
      );
    }
  }
  async createEigenBatchTransaction(insertBatchData, insertHashData) {
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();
    try {
      await queryRunner.manager.save(DaBatches, insertBatchData);
      if (insertHashData) {
        await queryRunner.manager.insert(DaBatchTransactions, insertHashData);
      }
      await queryRunner.commitTransaction();
    } catch (error) {
      this.logger.error(`create eigenlayer batch transaction error: ${error}`);
      await queryRunner.rollbackTransaction();
      return false;
    }
    await queryRunner.release();
    return true;
  }
  async handleWaitTransaction() {
    // const latestBlock = await this.getCurrentBlockNumber();
    // const { timestamp } = await this.web3.eth.getBlock(latestBlock);
    const totalElements = await this.getSccTotalElements();
    // const lTimestamp = Number(waitTxList[i].timestamp) / 1000;
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();
    try {
      // todo: lTimestamp + FraudProofWindow >= timestamp
      await queryRunner.manager
        .createQueryBuilder()
        .setLock('pessimistic_write')
        .update(L2ToL1)
        .set({ status: 'Ready for Relay' })
        .where('block <= :block', { block: totalElements })
        .andWhere('status = :status', { status: 'Waiting' })
        .execute();
      // update transactions to Ready for Relay
      // await queryRunner.manager.query(
      //   `UPDATE transactions SET l1l2_status=$1 WHERE l1l2_status=$2;`,
      //   [1, 0],
      // );
      await queryRunner.commitTransaction();
    } catch (error) {
      await queryRunner.rollbackTransaction();
    } finally {
      this.logger.log(`l2l1 change status to Waiting finish`);
    }
    await queryRunner.release();
  }
  async createL2L1Relation() {
    const unMergeTxList = await this.getRelayedEventByIsMerge(false);
    const l2ToL1UpdateList = [];
    const l2SentMessageEventsTxHashList = [];
    const l1RelayedMessageEventsTxHashList = [];
    for (let i = 0; i < unMergeTxList.length; i++) {
      const l2ToL1Transaction = await this.getL2ToL1TxByMsgHash(
        unMergeTxList[i].msg_hash,
      );
      if (l2ToL1Transaction) {
        l2ToL1UpdateList.push({
          hash: unMergeTxList[i].tx_hash,
          status: 'Relayed',
          l2_hash: l2ToL1Transaction.l2_hash
        })
        l2SentMessageEventsTxHashList.push(l2ToL1Transaction.l2_hash)
        l1RelayedMessageEventsTxHashList.push(unMergeTxList[i].tx_hash)
      }
    }
    const dataSource = getConnection();
    const queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    await queryRunner.startTransaction();
    try {
      await queryRunner.manager
        .createQueryBuilder()
        .setLock('pessimistic_write')
        .insert()
        .into(L2ToL1)
        .values(l2ToL1UpdateList)
        .orUpdate(["hash", "status"], ["l2_hash"], {
          skipUpdateIfNoValuesChanged: true
        })
        .execute();
      await queryRunner.manager
        .createQueryBuilder()
        .setLock('pessimistic_write')
        .update(L2SentMessageEvents)
        .set({ is_merge: true })
        .where({ tx_hash: In(l2SentMessageEventsTxHashList) })
        .execute();
      await queryRunner.manager
        .createQueryBuilder()
        .setLock('pessimistic_write')
        .update(L1RelayedMessageEvents)
        .set({ is_merge: true })
        .where({ tx_hash: In(l1RelayedMessageEventsTxHashList) })
        .execute();
      // update transactions to Ready for Relay
      // await queryRunner.manager.query(
      //   `UPDATE transactions SET l1_origin_tx_hash=$1, l1l2_type=$2 WHERE hash=$3;`,
      //   [unMergeTxList[i].tx_hash, 2, l2ToL1Transaction.l2_hash],
      // );
      await queryRunner.commitTransaction();
      this.logger.log(
        `create l2->l1 relation to l2_to_l1 table commit transaction finish`,
      );
    } catch (error) {
      this.logger.log(
        `create l2->l1 relation to l2_to_l1 table error ${error}`,
      );
      await queryRunner.rollbackTransaction();
    } finally {
      await queryRunner.release();
      this.logger.log(`create l2->l1 relation to l2_to_l1 table finish`);
    }
  }
  async syncSentEvents() {
    const startBlockNumber = await this.getSentEventsBlockNumber();
    const currentBlockNumber = await this.getCurrentBlockNumber();
    for (let i = startBlockNumber; i < currentBlockNumber; i += 10) {
      const start = i === 0 ? 0 : i + 1;
      const end = Math.min(i + 10, currentBlockNumber);
      const result = await this.createSentEvents(start, end);
      this.logger.log(
        `sync [${result.length}] l1_sent_message_events from block [${start}] to [${end}]`,
      );
    }
  }
  async syncRelayedEvents() {
    const startBlockNumber = await this.getRelayedEventsBlockNumber();
    const currentBlockNumber = await this.getCurrentBlockNumber();
    for (let i = startBlockNumber; i < currentBlockNumber; i += 10) {
      const start = i === 0 ? 0 : i + 1;
      const end = Math.min(i + 10, currentBlockNumber);
      const result = await this.createRelayedEvents(start, end);
      this.logger.log(
        `sync [${result.length}] l1_relayed_message_events from block [${start}] to [${end}]`,
      );
    }
  }
  async sync() {
    this.syncSentEvents();
    this.syncRelayedEvents();
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
  async getL2ToL1TxByMsgHash(msgHash: string) {
    return this.txnL2ToL1Repository.findOne({
      where: { msg_hash: msgHash },
    });
  }
  async getL1ToL2TxByMsgHash(msgHash: string) {
    return this.txnL1ToL2Repository.findOne({
      where: { msg_hash: msgHash },
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
  async getL1ToL2Relation() {
    const sentList = await this.sentEventsRepository.find();
    const result = [];
    for (const item of sentList) {
      const { target, sender, message, message_nonce } = item;
      const msgHash = this.verifyDomainCalldataHash({
        target: target.toString(),
        sender: sender.toString(),
        message: message.toString(),
        messageNonce: message_nonce.toString(),
      });
      const relayedResult =
        await this.l2IngestionService.getRelayedEventByMsgHash(msgHash);
      result.push({
        block_number: item.block_number,
        queue_index: message_nonce.toString(),
        l2_tx_hash: relayedResult.tx_hash.toString(),
        l1_tx_hash: item.tx_hash.toString(),
        gas_limit: item.gas_limit,
      });
    }
    return result;
  }
  async getL2ToL1Relation() {
    const sentList = await this.l2IngestionService.getAllSentEvents();
    const result = [];
    for (const item of sentList) {
      const { target, sender, message, message_nonce } = item;
      const msgHash = this.l2IngestionService.verifyDomainCalldataHash({
        target: target.toString(),
        sender: sender.toString(),
        message: message.toString(),
        messageNonce: message_nonce.toString(),
      });
      const relayedResult = await this.getRelayedEventByMsgHash(msgHash);
      result.push({
        message_nonce: message_nonce.toString(),
        l2_tx_hash: item.tx_hash.toString(),
        l1_tx_hash: relayedResult ? relayedResult.tx_hash.toString() : null,
      });
    }
    return result;
  }
  async getL1L2Transaction(address, page, page_size, type, order) {
    const result = [];
    const new_page = page - 1;
    if (type == 1) {
      const deposits = await this.txnL1ToL2Repository.find({
        where: { from: address },
        order: { queue_index: order },
        skip: new_page,
        take: page_size,
      });
      for (const item of deposits) {
        let l1_hash = '';
        let l2_hash = '';
        if (item.hash != null) {
          l1_hash = Buffer.from(item.hash).toString();
        }
        if (item.l2_hash != null) {
          l2_hash = Buffer.from(item.l2_hash).toString();
        }
        let token_name = '';
        let token_symbol = '';
        if (
          item.l2_token != '0x0000000000000000000000000000000000000000' ||
          item.l2_token != null
        ) {
          const queryToken = await this.tokensRepository.findOne({
            where: {
              contract_address_hash: Buffer.from(item.l2_token)
                .toString()
                .replace('0x', '\\x'),
            },
          });
          if (queryToken != null) {
            token_name = queryToken.name;
            token_symbol = queryToken.symbol;
          } else {
            token_name = item.name;
            token_symbol = item.symbol;
          }
        } else {
          token_name = item.name;
          token_symbol = item.symbol;
        }
        result.push({
          l1_hash: l1_hash,
          l2_hash: l2_hash,
          block: item.block,
          name: token_name,
          status: item.status,
          symbol: token_symbol,
          l1_token: Buffer.from(item.l1_token).toString(),
          l2_token: Buffer.from(item.l2_token).toString(),
          from: Buffer.from(item.from).toString(),
          to: Buffer.from(item.to).toString(),
          value: item.value,
        });
      }
    }
    if (type == 2) {
      const withdraw = await this.txnL2ToL1Repository.find({
        where: { from: address },
        order: { msg_nonce: order },
        skip: new_page,
        take: page_size,
      });
      for (const item of withdraw) {
        let l1_hash = '';
        let l2_hash = '';
        if (item.hash != null) {
          l1_hash = Buffer.from(item.hash).toString();
        }
        if (item.l2_hash != null) {
          l2_hash = Buffer.from(item.l2_hash).toString();
        }
        let token_name = '';
        let token_symbol = '';
        if (
          item.l2_token != '0x0000000000000000000000000000000000000000' ||
          item.l2_token != null
        ) {
          const queryToken = await this.tokensRepository.findOne({
            where: {
              contract_address_hash: Buffer.from(item.l2_token)
                .toString()
                .replace('0x', '\\x'),
            },
          });
          if (queryToken != null) {
            token_name = queryToken.name;
            token_symbol = queryToken.symbol;
          } else {
            token_name = item.name;
            token_symbol = item.symbol;
          }
        } else {
          token_name = item.name;
          token_symbol = item.symbol;
        }
        result.push({
          l1_hash: l1_hash,
          l2_hash: l2_hash,
          block: item.block,
          name: token_name,
          status: item.status,
          symbol: token_symbol,
          l1_token: Buffer.from(item.l1_token).toString(),
          l2_token: Buffer.from(item.l2_token).toString(),
          from: Buffer.from(item.from).toString(),
          to: Buffer.from(item.to).toString(),
          value: item.value,
        });
      }
    }
    return {
      ok: true,
      code: 2000,
      result: result,
    };
  }
  async syncEigenDaBatch(batchIndex) {
    try {
      const latestBatchIndex = await this.eigenlayerService.getLatestTransactionBatchIndex();
      this.logger.log(`[syncEigenDaBatch] latestBatchIndex: ${latestBatchIndex}`);
      if (batchIndex > Number(latestBatchIndex)) {
        return false;
      }
      const {
        data_store_id: fromStoreNumber
      } = await this.eigenlayerService.getRollupStoreByRollupBatchIndex(batchIndex);
      const {
        Index,
        StorePeriodLength,
        Confirmed,
        MsgHash,
        DurationDataStoreId,
        StoreNumber,
        Fee,
        InitTxHash,
        ConfirmTxHash
      } = await this.eigenlayerService.getDataStore(fromStoreNumber);
      if (Index === undefined || Index === '') return true;
      const CURRENT_TIMESTAMP = new Date().toISOString();
      const insertBatchData = {
        batch_index: batchIndex,
        batch_size: StorePeriodLength,
        status: Confirmed ? 'confirmed' : 'init',
        da_hash: utils.hexlify(MsgHash),
        store_id: DurationDataStoreId,
        store_number: StoreNumber,
        da_fee: Fee,
        da_init_hash: utils.hexlify(InitTxHash),
        da_store_hash: utils.hexlify(ConfirmTxHash),
        from_store_number: fromStoreNumber,
        inserted_at: CURRENT_TIMESTAMP,
        updated_at: CURRENT_TIMESTAMP
      }
      let insertHashData = null;
      // if Confirmed = true then get EigenDa tx list, else skip
      if (Confirmed) {
        const txHashList = await this.eigenlayerService.getTxn(StoreNumber) || [];
        const insertHashList = [];
        txHashList.forEach((item) => {
          insertHashList.push({
            batch_index: batchIndex,
            block_number: item.BlockNumber,
            tx_hash: item.TxHash,
            inserted_at: CURRENT_TIMESTAMP,
            updated_at: CURRENT_TIMESTAMP
          })
        })
        insertHashData = insertHashList
      }
      const result = await this.createEigenBatchTransaction(insertBatchData, insertHashData);
      return result;
    } catch (error) {
      this.logger.error(`[syncEigenDaBatch] error: ${error}`);
      return false;
    }
  }
  async getLastFromStoreNumber() {
    const result = await this.daBatchesRepository
      .createQueryBuilder()
      .select('Max(from_store_number)', 'fromStoreNumber')
      .getRawOne();
    return Number(result.fromStoreNumber) || 0;
  }
  async getLastBatchIndex() {
    const result = await this.daBatchesRepository
      .createQueryBuilder()
      .select('Max(batch_index)', 'batchIndex')
      .getRawOne();
    return Number(result.batchIndex) || 0;
  }
  // async syncEigenDaBatchTxn() {
  //   const data1 = await this.eigenlayerService.getDataStore(2);
  //   const data2 = await this.eigenlayerService.getDataStore(3);
  //   console.log(data1, data2);
  //   return {
  //     data1: {
  //       ...data1,
  //       MsgHash: utils.hexlify(data1.MsgHash),
  //       InitTxHash: utils.hexlify(data1.InitTxHash),
  //       ConfirmTxHash: utils.hexlify(data1.ConfirmTxHash),
  //       DataCommitment: utils.hexlify(data1.DataCommitment),
  //       SignatoryRecord: utils.hexlify(data1.SignatoryRecord),
  //     },
  //     data2: {
  //       ...data2,
  //       MsgHash: utils.hexlify(data2.MsgHash),
  //       InitTxHash: utils.hexlify(data2.InitTxHash),
  //       ConfirmTxHash: utils.hexlify(data2.ConfirmTxHash),
  //       DataCommitment: utils.hexlify(data2.DataCommitment),
  //       SignatoryRecord: utils.hexlify(data2.SignatoryRecord),
  //     },
  //   }
  // }
}
