`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[8:0]                      rdusedw,                    // 512-word FIFO uses a 9-bit used-word count
	input                            write_fifo_empty            // FIFO read-side empty flag(mem_clk domain)
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[ADDR_BITS - 1:0]                write_cnt;                   //write data counter
reg[1:0]                            write_addr_index_d0;
reg[1:0]                            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [15:0]                            wr_x;                       // current x position in one input row

reg [BURST_BITS - 1:0]				burst_cnt;
reg [BURST_BITS - 1:0]             burst_limit;              // words in this burst (supports a partial final burst)
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

// ---------------------------------------------------------------------------
// 时序优化:rdusedw 先打一拍再参与 into_burst
//
// rdusedw 来自写 FIFO 内部的 gray 指针解码,组合路径很长;
// 而 into_burst 又组合驱动 O_wr_busy -> App_wr_busy -> 两个读 FSM 的
// S_CHECK_FIFO 判据,在 125MHz(ext_mem_clk, 8ns)下形成一条
// "写FIFO指针 -> 写FSM突发判据 -> 读FSM状态" 的跨三个状态机长组合链。
// 实测布局布线报告:
//   Begin Point : frame_read_write_m0/write_buf/rd_addr_reg[0]
//   End Point   : frame_read_write_m0/frame_fifo_read2_m0/state_reg[1]
//   Slack       : -0.447ns   (ext_mem_clk -> ext_mem_clk, Fmax 118.4MHz < 125MHz)
// 读 FSM 一旦采到错误的 App_wr_busy,就会跳过或延迟一次突发,
// 造成读 FIFO 欠载 -> 像素重复/错位。淡化期间两路同时读,更容易暴露。
//
// rdusedw 只是"攒够一次突发的数据没有"的流量阈值,晚一拍判断没有任何功能影响,
// 因此这里插入一级流水寄存器,把长链切断,不改变互斥语义。
// ---------------------------------------------------------------------------
reg [8:0] rdusedw_r;
always @(posedge mem_clk or posedge rst) begin
    if (rst)
        rdusedw_r <= 9'd0;
    else
        rdusedw_r <= rdusedw;
end

wire into_burst;
assign into_burst = (((write_len_latch <= (rdusedw_r + write_cnt))||rdusedw_r > BURST_SIZE) && ~App_rd_busy);//当rd在突发时不会进入burst

assign App_wr_addr = {App_wr_addr_r[ADDR_BITS - 1:0]};
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
assign wr_burst_finish = (burst_limit != {BURST_BITS{1'b0}}) &&
                         (burst_cnt >= burst_limit);
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            //write finish at state 'S_END'
// SDRAM 忙(尤其自刷新)或写 FIFO 已空时不得把本拍计为有效写入。
// 地址、burst_cnt 和 write_cnt 都使用这个门控后的 App_wr_en 计数，
// 因而暂停后会从同一像素继续，不会写入 FIFO 中残留的旧字。
assign App_wr_en = App_wr_en_d0 & ~Sdr_busy & ~write_fifo_empty;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  2'b00;
		write_addr_index_d1    <=  2'b00;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
				if(write_addr_index_d1 == 2'd0)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_0;
				else if(write_addr_index_d1 == 2'd1)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_1;
				else if(write_addr_index_d1 == 2'd2)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_2;
				else if(write_addr_index_d1 == 2'd3)
					App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_3;
			end
		else if(App_wr_en)
			begin
				if(WRITE_V_FLIP)
				begin
					if(wr_x == VFLIP_LINE_LAST_X)
					begin
						wr_x <= 16'd0;
						App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
				else
					App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		// 写 FIFO 被抽空时必须立刻暂停突发,否则会从空 FIFO 读出上一帧残留的陈旧数据。
		// 触发场景:TF 卡长时间静置后首次访问响应变慢、或读卡过程中断,
		// 写侧数据流一停,原本"够 128 个字"的突发就会把 FIFO 抽干 →
		// 把陈旧数据当图像写进 SDRAM → 那一张图出现雪花。
		// 门控后:数据没到就等,SD 恢复后自动继续;若一直不到,
		// bmp_read / sd_card_bmp 的 2 秒超时会放弃本次加载,不会显示坏图。
		// rdusedw_r 是流量阈值(已打一拍),晚一拍最多多读 1 个字。
		if(!App_wr_en_r || burst_cnt >= burst_limit) begin
			App_wr_en_d0 <= 1'b0;
		end else if(App_wr_en && (burst_cnt == burst_limit - 1'b1)) begin
			// The word accepted this cycle is the last word in the burst.
			App_wr_en_d0 <= 1'b0;
		end else if((rdusedw_r != 0) && !write_fifo_empty) begin
			App_wr_en_d0 <= 1'b1;
		end else begin
			App_wr_en_d0 <= 1'b0;
		end
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		burst_limit <= ZERO[BURST_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
				end
				//write data counter reset, write_cnt <= 0;
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst write request, goto burst write state
				else if(into_burst)
				begin
					state <= S_WRITE_BURST;
					// Register the remaining length before entering the burst.  The old
					// per-cycle expression added burst_cnt + write_cnt and compared a
					// 21-bit value on the App_wr_en path; routed STA measured -1.854 ns.
					// Once this limit is latched, the hot path is only a BURST_BITS-wide
					// counter comparison and has identical transfer semantics.
					if ((write_len_latch - write_cnt) < BURST_SIZE)
						burst_limit <= write_len_latch - write_cnt;
					else
						burst_limit <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				// 上游读卡超时后会撤销旧请求并重新发起一次写帧请求。若旧帧恰好
				// 在一个未填满的 burst 中断粮，本状态原先只等 wr_burst_finish，
				// 新请求永远得不到 ACK，后续切图便永久卡住。新的 write_req 只会在
				// sd_card_bmp 已放弃旧帧后出现，因此优先终止旧 burst，并复用 S_ACK
				// 清 FIFO、锁存新地址和重新建立写事务。
				if(write_req_d2 == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_ACK;
				end
				//burst finish
				else if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					//write counter + burst length
					write_cnt <= write_cnt + burst_limit;
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(write_cnt < write_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
