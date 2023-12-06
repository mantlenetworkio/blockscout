import { Injectable, Logger, Inject, CACHE_MANAGER } from '@nestjs/common';
import { Cache } from 'cache-manager';
import { Interval, SchedulerRegistry } from '@nestjs/schedule';
import { L1IngestionService } from '../l1Ingestion/l1Ingestion.service';
import { L2IngestionService } from '../l2Ingestion/l2Ingestion.service';
import { ConfigService } from '@nestjs/config';
import { MonitorService } from 'src/monitor/monitor.service';
import { TransactionStatsService } from 'src/transaction_stats/transaction.stats.service';

const L1_SENT = 'l1_sent_block_number';
const L1_SENT_CURRENT_START = 'l1_sent_current_start_block_number';
const L1_SENT_CURRENT = 'l1_sent_current_block_number';
const L1_RELAYED = 'l1_relayed_block_number';
const L2_SENT = 'l2_sent_block_number';
const L2_RELAYED = 'l2_relayed_block_number';
const TXN_BATCH = 'txn_batch_block_number';
const STATE_BATCH = 'state_batch_block_number';
const DA_BATCH_INDEX = 'DA_BATCH_INDEX';
const SYNC_STEP = 200;
const SYNC_STEP_L2 = 2000;
const DA_MISS_UPDATE_LATEST_BATCH = 'DA_MISS_UPDATE_LATEST_BATCH';

@Injectable()
export class TasksService {
  constructor(
    private configService: ConfigService,
    private readonly l1IngestionService: L1IngestionService,
    private readonly l2IngestionService: L2IngestionService,
    private readonly monitorService: MonitorService,
    private readonly transactionStatsService: TransactionStatsService,
    @Inject(CACHE_MANAGER) private cacheManager: Cache,
    private schedulerRegistry: SchedulerRegistry,
  ) {
    this.initCache();
    const fixedL2ToL1TokenAddress0x000Bug = setInterval(async () => {
      try {
        const result =
          await this.l2IngestionService.fixedL2ToL1TokenAddress0x000Bug();
        if (result.length <= 0) {
          console.log({
            type: 'log',
            time: new Date().getTime(),
            msg: 'deleteInterval fixedL2ToL1TokenAddress0x000Bug',
          });
          this.schedulerRegistry.deleteInterval(
            'fixedL2ToL1TokenAddress0x000Bug',
          );
        }
      } catch (error) {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `error fixedL2ToL1TokenAddress0x000Bug: ${error?.message}`,
        });
      }
    }, 1000);
    this.schedulerRegistry.addInterval(
      'fixedL2ToL1TokenAddress0x000Bug',
      fixedL2ToL1TokenAddress0x000Bug,
    );
  }
  private readonly logger = new Logger(TasksService.name);
  async initCache() {
    let l1_sent_block_number = await this.cacheManager.get(L1_SENT);
    let l1_sent_current_start_block_number = await this.cacheManager.get(
      L1_SENT_CURRENT_START,
    );
    let l1_sent_current_block_number = await this.cacheManager.get(
      L1_SENT_CURRENT,
    );
    let l1_relayed_block_number = await this.cacheManager.get(L1_RELAYED);
    let l2_sent_block_number = await this.cacheManager.get(L2_SENT);
    let l2_relayed_block_number = await this.cacheManager.get(L2_RELAYED);
    let txn_batch_block_number = await this.cacheManager.get(TXN_BATCH);
    let state_batch_block_number = await this.cacheManager.get(STATE_BATCH);
    let da_batch_index = await this.cacheManager.get(DA_BATCH_INDEX);
    let da_miss_update_latest_batch =
      (await this.cacheManager.get(DA_MISS_UPDATE_LATEST_BATCH)) || 1;
    if (!l1_sent_block_number) {
      l1_sent_block_number =
        (await this.l1IngestionService.getSentEventsBlockNumber()) ||
        this.configService.get('L1_START_BLOCK_NUMBER');
    }
    if (!l1_sent_current_block_number) {
      l1_sent_current_block_number =
        (await this.l1IngestionService.getCurrentBlockNumber()) ||
        this.configService.get('L1_START_BACKTRACK_BLOCK_NUMBER');
      l1_sent_current_start_block_number = l1_sent_current_block_number;
    }
    if (!l1_relayed_block_number) {
      l1_relayed_block_number =
        (await this.l1IngestionService.getRelayedEventsBlockNumber()) ||
        this.configService.get('L1_START_BLOCK_NUMBER');
    }
    if (!l2_sent_block_number) {
      l2_sent_block_number =
        (await this.l2IngestionService.getSentEventsBlockNumber()) ||
        this.configService.get('L2_START_BLOCK_NUMBER');
    }
    if (!l2_relayed_block_number) {
      l2_relayed_block_number =
        (await this.l2IngestionService.getRelayedEventsBlockNumber()) ||
        this.configService.get('L2_START_BLOCK_NUMBER');
    }
    if (!txn_batch_block_number) {
      txn_batch_block_number =
        (await this.l1IngestionService.getTxnBatchBlockNumber()) ||
        this.configService.get('L1_START_BLOCK_NUMBER');
    }
    if (!state_batch_block_number) {
      state_batch_block_number =
        (await this.l1IngestionService.getStateBatchBlockNumber()) ||
        this.configService.get('L1_START_BLOCK_NUMBER');
    }
    if (!da_batch_index) {
      da_batch_index =
        (await this.l1IngestionService.getLastBatchIndex()) + 1 || 1;
    }
    await this.cacheManager.set(L1_SENT, Number(l1_sent_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(
      L1_SENT_CURRENT,
      Number(l1_sent_current_block_number),
      {
        ttl: 0,
      },
    );
    await this.cacheManager.set(
      L1_SENT_CURRENT_START,
      Number(l1_sent_current_start_block_number),
      {
        ttl: 0,
      },
    );
    await this.cacheManager.set(L1_RELAYED, Number(l1_relayed_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(L2_SENT, Number(l2_sent_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(L2_RELAYED, Number(l2_relayed_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(TXN_BATCH, Number(txn_batch_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(STATE_BATCH, Number(state_batch_block_number), {
      ttl: 0,
    });
    await this.cacheManager.set(DA_BATCH_INDEX, Number(da_batch_index), {
      ttl: 0,
    });

    await this.cacheManager.set(
      DA_MISS_UPDATE_LATEST_BATCH,
      Number(da_miss_update_latest_batch),
      {
        ttl: 0,
      },
    );

    //this.sync_token_price_history();
    this.updateDaBatchMissed();
  }

  @Interval(1000)
  async l1_sent_latest() {
    // sync from latest block
    let end = 0;
    const currentL1BlockNumber =
      await this.l1IngestionService.getCurrentBlockNumber();
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: `l1 sent currentBlockNumber: ${currentL1BlockNumber}`,
    });
    const currentBlockNumber = currentL1BlockNumber - 1;
    const start = Number(await this.cacheManager.get(L1_SENT_CURRENT));

    if (currentBlockNumber - start > SYNC_STEP) {
      end = start + SYNC_STEP;
    } else {
      end =
        start - SYNC_STEP > currentBlockNumber
          ? start - SYNC_STEP
          : currentBlockNumber;
    }

    if (currentBlockNumber > start + 1) {
      const inserted = await this.l1IngestionService.createSentEvents(
        start + 1,
        end,
      );

      if (inserted) {
        this.cacheManager.set(L1_SENT_CURRENT, end, { ttl: 0 });
        console.log(
          `sync l1_sent_latest_message_events from block [${
            start + 1
          }] to [${end}]`,
        );
      } else {
        this.logger.error(
          '-------- insert l1 sent latest message events failed -----------',
        );
      }
    }
  }

  @Interval('l1_sent_history', 1000)
  async l1_sent_history() {
    // sync history block, stop when sync reach latest starting block.
    let end = 0;
    let reachSyncLatest = false;
    const currentInterval =
      this.schedulerRegistry.getInterval('l1_sent_history');
    const l1SyncLatestStartBlock = Number(
      await this.cacheManager.get(L1_SENT_CURRENT_START),
    );

    console.log(
      `l1 sent_history to latest start block: , ${l1SyncLatestStartBlock}`,
    );
    const start = Number(await this.cacheManager.get(L1_SENT));
    if (l1SyncLatestStartBlock - start > SYNC_STEP) {
      end = start + SYNC_STEP;
    } else {
      end = l1SyncLatestStartBlock;
      reachSyncLatest = true;
      console.log(
        `l1 sent_history reach: , ${start} to ${end}. latest start block is ${l1SyncLatestStartBlock}`,
      );
    }
    if (l1SyncLatestStartBlock > start + 1) {
      const inserted = await this.l1IngestionService.createSentEvents(
        start + 1,
        end,
      );
      if (inserted) {
        this.cacheManager.set(L1_SENT, end, { ttl: 0 });
        if (reachSyncLatest) {
          console.log(`sync l1 sent_history done, end job.`);
          clearInterval(currentInterval);
          return;
        }
      } else {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `insert l1 sent message events failed start: ${start}, end: ${end}`,
        });
      }
    }
  }

  @Interval(1000)
  async l1_relayed() {
    let end = 0;
    const currentL1BlockNumber =
      await this.l1IngestionService.getCurrentBlockNumber();
    const currentBlockNumber = currentL1BlockNumber - 1;
    const start = Number(await this.cacheManager.get(L1_RELAYED));
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: {
        message: `l1 relayed latest number`,
        latestNumber: currentL1BlockNumber,
        startNumber: start,
      },
    });
    if (currentBlockNumber - start > SYNC_STEP) {
      end = start + SYNC_STEP;
    } else {
      end =
        start - SYNC_STEP > currentBlockNumber
          ? start - SYNC_STEP
          : currentBlockNumber;
    }
    if (currentBlockNumber > start + 1) {
      const inserted = await this.l1IngestionService.createRelayedEvents(
        start + 1,
        end,
      );
      if (inserted) {
        this.cacheManager.set(L1_RELAYED, end, { ttl: 0 });
      } else {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `insert l1 relayed message events failed start: ${start}, end: ${end}`,
        });
      }
    }
  }
  @Interval(1000)
  async l2_sent() {
    let end = 0;
    const currentL2BlockNumber =
      await this.l2IngestionService.getCurrentBlockNumber();
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: `l2 sent currentBlockNumber: ${currentL2BlockNumber}`,
    });
    const currentBlockNumber = currentL2BlockNumber - 1;
    const start = Number(await this.cacheManager.get(L2_SENT));
    if (currentBlockNumber - start > SYNC_STEP_L2) {
      end = start + SYNC_STEP_L2;
    } else {
      end =
        start - SYNC_STEP_L2 > currentBlockNumber
          ? start - SYNC_STEP_L2
          : currentBlockNumber;
    }
    if (currentBlockNumber > start + 1) {
      const inserted = await this.l2IngestionService.createSentEvents(
        start + 1,
        end,
      );
      if (inserted) {
        this.cacheManager.set(L2_SENT, end, { ttl: 0 });
      } else {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `insert l2 sent message events failed: ${start}, end: ${end}`,
        });
      }
    }
  }
  @Interval(1000)
  async l2_relayed() {
    let end = 0;
    const currentL2BlockNumber =
      await this.l2IngestionService.getCurrentBlockNumber();
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: `l2 relayed currentBlockNumber: ${currentL2BlockNumber}`,
    });
    const currentBlockNumber = currentL2BlockNumber - 1;
    const start = Number(await this.cacheManager.get(L2_RELAYED));
    if (currentBlockNumber - start > SYNC_STEP_L2) {
      end = start + SYNC_STEP_L2;
    } else {
      end =
        start - SYNC_STEP_L2 > currentBlockNumber
          ? start - SYNC_STEP_L2
          : currentBlockNumber;
    }
    if (currentBlockNumber > start + 1) {
      const inserted = await this.l2IngestionService.createRelayedEvents(
        start + 1,
        end,
      );
      if (inserted) {
        this.cacheManager.set(L2_RELAYED, end, { ttl: 0 });
      } else {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `insert l2 relayed message events failed: ${start}, end: ${end}`,
        });
      }
    }
  }

  @Interval(1000)
  async state_batch() {
    let end = 0;
    const currentL1BlockNumber =
      await this.l1IngestionService.getCurrentBlockNumber();
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: `state batch currentBlockNumber: ${currentL1BlockNumber}`,
    });
    // the latest block might get empty passed events
    const currentBlockNumber = currentL1BlockNumber - 1;
    const start = Number(await this.cacheManager.get(STATE_BATCH));
    // current = 100   start = 94  SYNC_STEP = 10
    if (currentBlockNumber - start > SYNC_STEP) {
      end = start + SYNC_STEP;
    } else {
      end =
        start - SYNC_STEP > currentBlockNumber
          ? start - SYNC_STEP
          : currentBlockNumber;
    }
    if (currentBlockNumber >= start + 1) {
      const result = await this.l1IngestionService
        .createStateBatchesEvents(start + 1, end)
        .catch((e) => {
          console.log({
            type: 'ERROR',
            time: new Date().getTime(),
            msg: {
              message: `insert state batch failed ${e?.message}`,
              start,
              end,
            },
          });
        });
      if (result) {
        const insertData =
          !result || result.length <= 0 ? [] : result[0].identifiers || [];
        console.log({
          type: 'log',
          time: new Date().getTime(),
          msg: {
            message: 'sync state batch from block',
            start,
            end,
            insertDataLength: insertData.length,
          },
        });
        await this.cacheManager.set(STATE_BATCH, end, { ttl: 0 });
      } else {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: 'result insert state batch data failed',
        });
      }
    } else {
      console.log({
        type: 'log',
        time: new Date().getTime(),
        msg: '',
      });
    }
  }

  @Interval(2000)
  async l1l2_merge() {
    try {
      await this.l1IngestionService.createL1L2Relation();
    } catch (error) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `error l1->l2 [handle_l1l2_merge]: ${error?.message}`,
      });
    }
  }
  @Interval(2000)
  async l2l1_merge() {
    try {
      await this.l1IngestionService.createL2L1Relation();
    } catch (error) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `error l1->l2 [handle_l2l1__merge]: ${error?.message}`,
      });
    }
  }
  @Interval(2000)
  async l2l1_merge_waiting() {
    try {
      await this.l2IngestionService.handleWaitTransaction();
    } catch (error) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `error l1l2 [handle_l2l1_merge_waiting]: ${error?.message}`,
      });
    }
  }
  @Interval(1000)
  async eigen_da_batch_txns() {
    const fromStoreNumber = Number(await this.cacheManager.get(DA_BATCH_INDEX));
    console.log({
      type: 'log',
      time: new Date().getTime(),
      msg: `syncEigenDaBatch start eigenda service fromStoreNumber: ${fromStoreNumber}`,
    });
    const result = await this.l1IngestionService
      .syncEigenDaBatch(fromStoreNumber)
      .catch((error) => {
        console.log({
          type: 'ERROR',
          time: new Date().getTime(),
          msg: `[syncEigenDaBatch] error eigen da batches error: ${error?.message}`,
        });
      });
    if (result) {
      await this.cacheManager.set(DA_BATCH_INDEX, fromStoreNumber + 1, {
        ttl: 0,
      });
    }
  }

  //@Interval(1800000)
  //async sync_token_price_history() {
  //  this.l1IngestionService.syncTokenPriceHistory();
  //}

  //@Interval(10000)
  //async sync_token_price_real_time() {
  //  this.l1IngestionService.syncTokenPriceRealTime();
  //}

  @Interval(60000)
  async updateReorgBlockMessage() {
    this.l1IngestionService.updateReorgBlockMessage().catch((e) => {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `update reorg block failed ${e?.message}`,
      });
    });
  }

  @Interval(1000)
  async monitor_service() {
    this.monitorService.missBlockNumber();
    this.monitorService.syncBridgeData();
  }

  @Interval(300000)
  async updateDaBatchMissed() {
    try {
      const { batchIndex } =
        await this.l1IngestionService.getLatestTransactionBatchIndex();
      if (batchIndex && batchIndex > 0) {
        const maxBatchIndex = batchIndex - 1;
        const start = Number(
          await this.cacheManager.get(DA_MISS_UPDATE_LATEST_BATCH),
        );
        const step = 200;
        const end =
          start + step >= maxBatchIndex ? maxBatchIndex : start + step;
        console.log({
          type: 'log',
          time: new Date().getTime(),
          msg: `update missed eigenda start and end: ${start} ${end}`,
        });
        const compareList = await this.l1IngestionService.getEmptyEigenDaData(
          start,
          end,
        );
        console.log({
          type: 'log',
          time: new Date().getTime(),
          msg: `update missed eigenda data compare list length: ${compareList?.length}`,
        });
        if (compareList?.length > 0) {
          const list = [],
            shouldUpdateList = [];
          for (let i = start; i <= end; i++) {
            list.push(i);
          }
          list.forEach((l) => {
            if (compareList.every((e) => Number(e.batch_index) !== l)) {
              shouldUpdateList.push(l);
            }
          });
          console.log({
            type: 'log',
            time: new Date().getTime(),
            msg: {
              message: `update missed eigenda data should update list`,
              shouldUpdateList,
            },
          });
          if (shouldUpdateList?.length > 0) {
            Promise.all(
              shouldUpdateList.map((s) =>
                this.l1IngestionService.updateDaBatchMissed(s),
              ),
            )
              .then((res) => {
                console.log({
                  type: 'log',
                  time: new Date().getTime(),
                  msg: {
                    message: `update missed eigenda data successful`,
                    updatedList: shouldUpdateList,
                  },
                });
                this.cacheManager.set(DA_MISS_UPDATE_LATEST_BATCH, end, {
                  ttl: 0,
                });
              })
              .catch((e) => {
                console.log({
                  type: 'ERROR',
                  time: new Date().getTime(),
                  msg: `update missed eigenda batches error: ${e?.message}`,
                });
              });
          } else {
            console.log({
              type: 'log',
              time: new Date().getTime(),
              msg: {
                message: `update missed eigenda data from and start does need to update`,
                start,
                end,
              },
            });
            this.cacheManager.set(DA_MISS_UPDATE_LATEST_BATCH, end, { ttl: 0 });
          }
        }
      }
    } catch (e) {
      console.log({
        type: 'ERROR',
        time: new Date().getTime(),
        msg: `update missed eigenda batches catch error: ${e?.message}`,
      });
    }
  }
  @Interval(60000)
  async syncFeeVaultBalance() {
    // BVM_SequencerFeeVault: 0x4200000000000000000000000000000000000011
    await this.l2IngestionService.syncFeeVaultBalance();
  }

  @Interval(3150)
  async updateTransactionStats() {
    this.transactionStatsService.updateTransactionStats();
  }

  @Interval(3550)
  async updateLast24HrsStats() {
    this.transactionStatsService.updateLast24HrsStats();
  }
}
