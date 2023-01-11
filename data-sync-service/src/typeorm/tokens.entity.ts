import { Column, Entity, PrimaryColumn } from 'typeorm';

@Entity()
export class Tokens {
  @PrimaryColumn({ type: 'bytea', name: 'contract_address_hash' })
  contract_address_hash: string;

  @Column({ type: 'varchar', length: 255 })
  name: string;

  @Column({ type: 'varchar', length: 255 })
  symbol: string;

  @Column({ type: 'numeric', precision: 100 })
  total_supply: number;

  @Column({ type: 'varchar', length: 255 })
  type: string;
}
