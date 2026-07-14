defmodule Explorer.Chain.ScaledUi.Events do
  @moduledoc "ERC-8056 and scheduled-extension event topics and interface identifiers."

  @ui_multiplier_updated_topic "0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055"
  @transfer_with_ui_amount_topic "0x0226a2f5c1ae0e071aeec3d4ebafcefdc5c549be11f40ed27e76e802acccf374"
  @ui_multiplier_change_overwritten_topic "0x62204eb4daab41a604e7262a5dca11bd936210002ddfaa885fad182b677ff92c"

  @core_interface_id "0xa60bf13d"
  @scheduled_interface_id "0xeb0093dd"

  def ui_multiplier_updated_topic, do: @ui_multiplier_updated_topic
  def transfer_with_ui_amount_topic, do: @transfer_with_ui_amount_topic
  def ui_multiplier_change_overwritten_topic, do: @ui_multiplier_change_overwritten_topic

  def all_topics do
    [
      @ui_multiplier_updated_topic,
      @transfer_with_ui_amount_topic,
      @ui_multiplier_change_overwritten_topic
    ]
  end

  def core_interface_id, do: @core_interface_id
  def scheduled_interface_id, do: @scheduled_interface_id
end
