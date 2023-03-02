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

  @PrimaryColumn({ type: 'bytea' })
  data_commitment: string;
  @PrimaryColumn({ type: 'int8' })
  stakes_from_block_number: number;
  @PrimaryColumn({ type: 'timestamp' })
  init_time: Date;
  @PrimaryColumn({ type: 'timestamp' })
  expire_time: Date;
  @PrimaryColumn({ type: 'int8' })
  duration: number;
  @PrimaryColumn({ type: 'int8' })
  num_sys: number;
  @PrimaryColumn({ type: 'int8' })
  num_par: number;
  @PrimaryColumn({ type: 'int8' })
  degree: number;
  @PrimaryColumn({ type: 'bytea' })
  confirmer: string;
  @PrimaryColumn({ type: 'bytea' })
  header: string;
  @Column({ type: 'numeric', precision: 100 })
  init_gas_used: number;
  @PrimaryColumn({ type: 'int8' })
  init_block_number: number;
  @PrimaryColumn({ type: 'varchar' })
  eth_signed: string;
  @PrimaryColumn({ type: 'varchar' })
  eigen_signed: string;
  @PrimaryColumn({ type: 'bytea' })
  signatory_record: string;
  @Column({ type: 'numeric', precision: 100 })
  confirm_gas_used: number;
}
