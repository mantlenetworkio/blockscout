import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class DaBatchTransactions {
  @Column({ type: 'int8' })
  batch_index: number;

  @PrimaryColumn({ type: 'bytea' })
  tx_hash: string;

  @Column({ type: 'bigint' })
  block_number: string;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  inserted_at: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  updated_at: Date;
}
