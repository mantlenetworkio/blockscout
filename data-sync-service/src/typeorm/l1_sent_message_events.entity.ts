import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class L1SentMessageEvents {
  @Column({ type: 'bytea' })
  tx_hash: string;

  @Column({ type: 'bigint' })
  block_number: string;

  @Column({ type: 'bytea' })
  target: string;

  @Column({ type: 'bytea' })
  sender: string;

  @Column({ type: 'bytea' })
  message: string;

  @Column({ type: 'boolean' })
  is_merge: boolean;

  @Column({ type: 'bytea' })
  signature: string;

  @PrimaryColumn({ type: 'numeric', precision: 100 })
  message_nonce: number;

  @Column({ type: 'numeric', precision: 100 })
  gas_limit: number;

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

