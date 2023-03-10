import { Module } from '@nestjs/common';
import { L2IngestionService } from './l2Ingestion.service';
import { TypeOrmModule } from '@nestjs/typeorm';
import { L2RelayedMessageEvents, L2SentMessageEvents, L2ToL1 } from 'src/typeorm';

@Module({
  imports: [
    TypeOrmModule.forFeature([L2RelayedMessageEvents, L2SentMessageEvents, L2ToL1]),
  ],
  providers: [L2IngestionService],
  exports: [L2IngestionService],
})
export class L2IngestionModule {}
