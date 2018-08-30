// ***************************************************************************
// ***************************************************************************
// Copyright 2014 - 2017 (c) Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/master/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************

module axi_dmac_response_manager #(
  parameter DMA_DATA_WIDTH_SRC = 64,
  parameter DMA_DATA_WIDTH_DEST = 64,
  parameter DMA_LENGTH_WIDTH = 24,
  parameter BYTES_PER_BURST_WIDTH = 7,
  parameter BYTES_PER_BEAT_WIDTH_SRC = $clog2(DMA_DATA_WIDTH_SRC/8),
  parameter ASYNC_CLK_DEST_REQ = 1
)(
  // Interface to destination side
  input dest_clk,
  input dest_resetn,

  input dest_response_valid,
  output dest_response_ready,
  input [1:0] dest_response_resp,
  input dest_response_partial,
  input dest_response_resp_eot,
  input [BYTES_PER_BURST_WIDTH-1:0] dest_response_data_burst_length,

  // Interface to processor
  input req_clk,
  input req_resetn,

  output reg response_eot = 1'b0,
  output reg [DMA_LENGTH_WIDTH-1:0] measured_transfer_length = 'h0,
  output reg response_partial = 1'b0,
  output reg response_valid = 1'b0,
  input response_ready,

  // Interface to requester side
  input completion_req_valid,
  input completion_req_last,
  input [1:0] completion_transfer_id
);

localparam STATE_IDLE         = 3'h0;
localparam STATE_ACC1         = 3'h1;
localparam STATE_ACC2         = 3'h2;
localparam STATE_WRITE_RESPR  = 3'h3;
localparam STATE_ZERO_COMPL   = 3'h4;
localparam STATE_WRITE_ZRCMPL = 3'h5;

reg [2:0] state = STATE_IDLE;
reg [2:0] nx_state;

localparam DEST_SRC_RATIO = DMA_DATA_WIDTH_DEST/DMA_DATA_WIDTH_SRC;

localparam DEST_SRC_RATIO_WIDTH = DEST_SRC_RATIO > 64 ? 7 :
  DEST_SRC_RATIO > 32 ? 6 :
  DEST_SRC_RATIO > 16 ? 5 :
  DEST_SRC_RATIO > 8 ? 4 :
  DEST_SRC_RATIO > 4 ? 3 :
  DEST_SRC_RATIO > 2 ? 2 :
  DEST_SRC_RATIO > 1 ? 1 : 0;

localparam BYTES_PER_BEAT_WIDTH = DEST_SRC_RATIO_WIDTH + BYTES_PER_BEAT_WIDTH_SRC;
localparam BURST_LEN_WIDTH = BYTES_PER_BURST_WIDTH - BYTES_PER_BEAT_WIDTH;

wire do_acc_st1;
wire do_acc_st2;
reg req_eot = 1'b0;
reg req_response_partial = 1'b0;
reg [BYTES_PER_BURST_WIDTH-1:0] req_response_dest_data_burst_length = 'h0;
reg [BYTES_PER_BURST_WIDTH-1:0] req_burst_length_adjusted = 'h0;

wire response_dest_valid;
reg response_dest_ready = 1'b1;
wire [1:0] response_dest_resp;
wire response_dest_resp_eot;
wire [BYTES_PER_BURST_WIDTH-1:0] response_dest_data_burst_length;

wire [BURST_LEN_WIDTH-1:0] burst_lenght;
reg [BURST_LEN_WIDTH-1:0] burst_pointer_end;

reg [1:0] to_complete_count = 'h0;
reg [1:0] transfer_id = 'h0;
reg completion_req_last_found = 1'b0;

util_axis_fifo #(
  .DATA_WIDTH(BYTES_PER_BURST_WIDTH+1+1),
  .ADDRESS_WIDTH(0),
  .ASYNC_CLK(ASYNC_CLK_DEST_REQ)
) i_dest_response_fifo (
  .s_axis_aclk(dest_clk),
  .s_axis_aresetn(dest_resetn),
  .s_axis_valid(dest_response_valid),
  .s_axis_ready(dest_response_ready),
  .s_axis_empty(),
  .s_axis_data({dest_response_data_burst_length,
                dest_response_partial,
                dest_response_resp_eot}),
  .s_axis_room(),

  .m_axis_aclk(req_clk),
  .m_axis_aresetn(req_resetn),
  .m_axis_valid(response_dest_valid),
  .m_axis_ready(response_dest_ready),
  .m_axis_data({response_dest_data_burst_length,
                response_dest_partial,
                response_dest_resp_eot}),
  .m_axis_level()
);

always @(posedge req_clk)
begin
  if (response_dest_valid & response_dest_ready) begin
    req_eot <= response_dest_resp_eot;
    req_response_partial <= response_dest_partial;
    req_response_dest_data_burst_length <= response_dest_data_burst_length;
  end
end

always @(posedge req_clk)
begin
  if (req_resetn == 1'b0) begin
    response_dest_ready <= 1'b1;
  end else begin
    response_dest_ready <= (nx_state == STATE_IDLE);
  end
end

always @(posedge req_clk)
begin
  if (req_resetn == 1'b0) begin
    response_eot <= 1'b0;
    response_partial <= 1'b0;
  end else if (state == STATE_ZERO_COMPL) begin
    response_eot <= 1'b1;
    response_partial <= 1'b0;
  end else if (do_acc_st2 == 1'b1) begin
    response_eot <= req_eot;
    response_partial <= req_response_partial;
  end
end

always @(posedge req_clk)
begin
  if (req_resetn == 1'b0) begin
    response_valid <= 1'b0;
  end else begin
    if (nx_state == STATE_WRITE_RESPR || nx_state == STATE_WRITE_ZRCMPL) begin
      response_valid <= 1'b1;
    end else if (response_ready == 1'b1) begin
      response_valid <= 1'b0;
    end
  end
end

// transform the free running pointer into burst length
assign burst_lenght = req_response_dest_data_burst_length[BYTES_PER_BURST_WIDTH-1 -: BURST_LEN_WIDTH] -
                      burst_pointer_end - 1'b1;

always @(posedge req_clk)
begin
  if (req_resetn == 1'b0) begin
    burst_pointer_end <= {BURST_LEN_WIDTH{1'b1}};
  end else if (do_acc_st1) begin
    burst_pointer_end <= req_response_dest_data_burst_length[BYTES_PER_BURST_WIDTH-1 -: BURST_LEN_WIDTH];
    req_burst_length_adjusted[BYTES_PER_BURST_WIDTH-1 -: BURST_LEN_WIDTH] <= burst_lenght;
    req_burst_length_adjusted[BYTES_PER_BEAT_WIDTH-1 : 0] <=
      req_response_dest_data_burst_length[BYTES_PER_BEAT_WIDTH-1: 0];
  end
end

always @(posedge req_clk)
begin
  if (response_valid == 1'b1 && response_ready == 1'b1 && response_eot == 1'b1) begin
    measured_transfer_length <= 'h0;
  end else begin
    if (do_acc_st2) begin
      measured_transfer_length <= measured_transfer_length + req_burst_length_adjusted + 1'b1;
    end
  end
end

always @(*) begin
  nx_state = state;
  case (state)
    STATE_IDLE: begin
      if (response_dest_valid == 1'b1) begin
        nx_state = STATE_ACC1;
      end else if (|to_complete_count) begin
        if (transfer_id == completion_transfer_id)
          nx_state = STATE_ZERO_COMPL;
      end
    end
    STATE_ACC1: begin
      nx_state = STATE_ACC2;
    end
    STATE_ACC2: begin
      nx_state = STATE_WRITE_RESPR;
    end
    STATE_WRITE_RESPR: begin
      if (response_ready == 1'b1) begin
        nx_state = STATE_IDLE;
      end
    end
    STATE_ZERO_COMPL: begin
      if (|to_complete_count) begin
        nx_state = STATE_WRITE_ZRCMPL;
      end else begin
        if (completion_req_last_found == 1'b1) begin
          nx_state = STATE_IDLE;
        end
      end
    end
    STATE_WRITE_ZRCMPL:begin
      if (response_ready == 1'b1) begin
        nx_state = STATE_ZERO_COMPL;
      end
    end
    default: begin
      nx_state = STATE_IDLE;
    end
  endcase
end

always @(posedge req_clk) begin
  if (req_resetn == 1'b0) begin
    state <= STATE_IDLE;
  end else begin
    state <= nx_state;
  end
end

assign do_acc_st1 = state == STATE_ACC1;
assign do_acc_st2 = state == STATE_ACC2;

// Once the last completion request from request generator is received 
// we can wait for completions from the destination side
always @(posedge req_clk) begin
  if (req_resetn == 1'b0) begin
    completion_req_last_found <= 1'b0;
  end else if (completion_req_valid) begin
    completion_req_last_found <= completion_req_last;
  end else if (state ==STATE_ZERO_COMPL && ~(|to_complete_count)) begin
    completion_req_last_found <= 1'b0;
  end
end

// Track transfers so we can tell when did the destination completed all its
// transfers  
always @(posedge req_clk) begin
  if (req_resetn == 1'b0) begin
    transfer_id <= 'h0;
  end else if ((state == STATE_ACC1 && req_eot) || do_compl) begin
    transfer_id <= transfer_id + 1;
  end
end

assign do_compl = (state == STATE_WRITE_ZRCMPL) && response_ready;

// Count how many transfers we need to complete 
always @(posedge req_clk) begin
  if (req_resetn == 1'b0) begin
    to_complete_count <= 'h0;
  end else if (completion_req_valid & ~do_compl) begin
    to_complete_count <= to_complete_count + 1;
  end else if (~completion_req_valid & do_compl) begin
    to_complete_count <= to_complete_count - 1;
  end
end

endmodule