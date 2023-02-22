import { ConfigService } from '@nestjs/config';
import { Injectable, Logger } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
// source /Users/bj89182ml/.gvm/scripts/gvm

@Injectable()
export class EigenlayerService {
  private readonly logger = new Logger(EigenlayerService.name);
  constructor(
    private readonly httpService: HttpService,
    private configService: ConfigService
  ) {}

  async getTxn(storeNumber: number) {
    const { data } = await firstValueFrom(
      this.httpService.post(`${this.configService.get('EIGEN_DA_URL')}/browser/GetTransactionListByStoreNumber`, {
        store_number: Number(storeNumber)
      }, {
        headers: {
          'Content-Type': 'application/json'
        }
      })
    );
    return data;
  }
  async getDataStore(fromStoreNumber: number) {
    const { data } = await firstValueFrom(
      this.httpService.post(`${this.configService.get('EIGEN_DA_URL')}/browser/getDataStoreById`, {
        store_id: fromStoreNumber.toString()
        // eigen_contract_addr: this.configService.get('DA_ADDRESS')
      }, {
        headers: {
          'Content-Type': 'application/json'
        }
      })
    );
    return data;
  }
  
  async getLatestTransactionBatchIndex() {
    const { data } = await firstValueFrom(
      this.httpService.get(`${this.configService.get('EIGEN_DA_URL')}/eigen/getLatestTransactionBatchIndex`)
    );
    return data;
  }
  async getRollupStoreByRollupBatchIndex(batchIndex: number) {
    const { data } = await firstValueFrom(
      this.httpService.post(`${this.configService.get('EIGEN_DA_URL')}/eigen/getRollupStoreByRollupBatchIndex`, {
        batch_index: batchIndex
      }, {
        headers: {
          'Content-Type': 'application/json'
        }
      })
    );
    return data;
  }
}
