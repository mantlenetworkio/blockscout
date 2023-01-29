import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class L2RelayedMessageEvents {
  @Column({ type: 'bytea' })
  tx_hash: string;

  @Column({ type: 'bigint' })
  block_number: number;

  @PrimaryColumn({ type: 'bytea' })
  msg_hash: string;

  @Column({ type: 'bytea' })
  signature: string;

  @Column({ type: 'boolean' })
  is_merge: boolean;

  @Column({ type: 'timestamp' })
  timestamp: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  inserted_at: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  updated_at: Date;
}
