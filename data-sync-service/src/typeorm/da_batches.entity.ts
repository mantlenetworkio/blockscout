import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class DaBatches {
  @Column({ type: 'int8' })
  batch_index: number;
  
  @Column({ type: 'int8'})
  batch_size: number;

  @Column({ type: 'varchar', length: 255 })
  status: string;

  // @Column({ type: 'int8' })
  // start_block: number;

  // @Column({ type: 'int8' })
  // end_block: number;

  @PrimaryColumn({ type: 'bytea' })
  da_hash: string;

  @Column({ type: 'int8' })
  store_id: number;

  @Column({ type: 'int8' })
  store_number: number;

  @Column({ type: 'numeric', precision: 100 })
  da_fee: number;

  @Column({ type: 'bytea' })
  da_init_hash: string;

  @Column({ type: 'bytea' })
  da_store_hash: string;

  @Column({ type: 'int8' })
  from_store_number: number;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  inserted_at: Date;

  @Column({ type: 'timestamp', default: () => 'CURRENT_TIMESTAMP' })
  updated_at: Date;
}
