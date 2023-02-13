import { Module } from '@nestjs/common';
import { EigenlayerService } from './eigenlayer.service';
import { HttpModule } from '@nestjs/axios';

@Module({
  imports: [HttpModule],
  providers: [EigenlayerService],
  exports: [EigenlayerService],
})
export class EigenlayerModule {}
