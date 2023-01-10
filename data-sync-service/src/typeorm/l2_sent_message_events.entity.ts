import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class L2SentMessageEvents {
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

  @Column({ type: 'bytea' })
  signature: string;

  @Column({ type: 'boolean' })
  is_merge: boolean;

  @PrimaryColumn({ type: 'numeric', precision: 100 })
  message_nonce: number;

  @Column({ type: 'numeric', precision: 100 })
  gas_limit: number;

  @Column({ type: 'timestamp' })
  timestamp: Date;

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

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  inserted_at: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  updated_at: Date;
}
