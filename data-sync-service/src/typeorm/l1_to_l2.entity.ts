import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class L1ToL2 {
  @PrimaryColumn({ type: 'bytea', name: 'hash' })
  hash: string;

  @Column({ type: 'bytea' })
  l2_hash: string;

  @Column({ type: 'bytea' })
  msg_hash: string;

  @Column({ type: 'int8' })
  block: number;

  @Column({ type: 'timestamp' })
  timestamp: Date;

  @Column({ type: 'bytea' })
  tx_origin: Date;

  @Column({ type: 'int8' })
  queue_index: number;

  @Column({ type: 'bytea' })
  target: string;

  @Column({ type: 'numeric', precision: 100 })
  gas_limit: number;

  @Column({ type: 'varchar', length: 255 })
  status: string;

  @Column({ type: 'boolean' })
  is_merge: boolean;

  @Column({ type: 'varchar' })
  name: string;

  @Column({ type: 'varchar' })
  symbol: string;

  @Column({ type: 'bytea' })
  l1_token: string;

  @Column({ type: 'bytea' })
  l2_token: string;

  @Column({ type: 'bytea' })
  from: string;

  @Column({ type: 'bytea' })
  to: string;

  @Column({ type: 'numeric', precision: 100 })
  value: string;

  @Column({ type: 'int8' })
  type: number;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  inserted_at: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  updated_at: Date;
}
