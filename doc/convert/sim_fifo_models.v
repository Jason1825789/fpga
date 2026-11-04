`timescale 1ns/1ps

// Simulation-only behavioral models for the generated 512x32 asynchronous FIFOs.
// The production RTL remains sourced from IP/afifo_*.v in the Anlogic project.
module wfifo_32_32_512 #(parameter DATA_WIDTH_W=32, DATA_WIDTH_R=32,
    parameter ADDR_WIDTH_W=9, ADDR_WIDTH_R=9,
    parameter AL_FULL_NUM=509, AL_EMPTY_NUM=2,
    parameter SHOW_AHEAD_EN=1'b1, parameter OUTREG_EN="NOREG") (
    input rst, input clkw, input clkr, input we, input [DATA_WIDTH_W-1:0] di,
    input re, output reg [DATA_WIDTH_R-1:0] dout,
    output reg valid, output full_flag, output empty_flag,
    output afull, output aempty,
    output [8:0] wrusedw, output [8:0] rdusedw
);
    reg [DATA_WIDTH_W-1:0] mem[0:511];
    reg [9:0] wptr, rptr;
    wire [9:0] used = wptr-rptr;
    assign full_flag = (used >= 10'd512);
    assign empty_flag = (used == 0);
    assign afull = (used >= AL_FULL_NUM);
    assign aempty = (used <= AL_EMPTY_NUM);
    assign wrusedw = used;
    assign rdusedw = used;
    always @(posedge clkw or posedge rst) begin
        if (rst) wptr <= 0;
        else if (we && !full_flag) begin
            mem[wptr[8:0]] <= di;
            wptr <= wptr+1'b1;
        end
    end
    always @(posedge clkr or posedge rst) begin
        if (rst) begin rptr <= 0; dout <= 0; valid <= 0; end
        else begin
            valid <= re && !empty_flag;
            if (re && !empty_flag) begin
                dout <= mem[rptr[8:0]];
                rptr <= rptr+1'b1;
            end
        end
    end
endmodule

module rfifo_32_32_512 #(parameter DATA_WIDTH_W=32, DATA_WIDTH_R=32,
    parameter ADDR_WIDTH_W=9, ADDR_WIDTH_R=9,
    parameter AL_FULL_NUM=509, AL_EMPTY_NUM=2,
    parameter SHOW_AHEAD_EN=1'b0, parameter OUTREG_EN="NOREG") (
    input rst, input clkw, input clkr, input we, input [DATA_WIDTH_W-1:0] di,
    input re, output reg [DATA_WIDTH_R-1:0] dout,
    output reg valid, output full_flag, output empty_flag,
    output afull, output aempty,
    output [8:0] wrusedw, output [8:0] rdusedw
);
    reg [DATA_WIDTH_W-1:0] mem[0:511];
    reg [9:0] wptr, rptr;
    wire [9:0] used = wptr-rptr;
    assign full_flag = (used >= 10'd512);
    assign empty_flag = (used == 0);
    assign afull = (used >= AL_FULL_NUM);
    assign aempty = (used <= AL_EMPTY_NUM);
    assign wrusedw = used;
    assign rdusedw = used;
    always @(posedge clkw or posedge rst) begin
        if (rst) wptr <= 0;
        else if (we && !full_flag) begin
            mem[wptr[8:0]] <= di;
            wptr <= wptr+1'b1;
        end
    end
    always @(posedge clkr or posedge rst) begin
        if (rst) begin rptr <= 0; dout <= 0; valid <= 0; end
        else begin
            valid <= re && !empty_flag;
            if (re && !empty_flag) begin
                dout <= mem[rptr[8:0]];
                rptr <= rptr+1'b1;
            end
        end
    end
endmodule
