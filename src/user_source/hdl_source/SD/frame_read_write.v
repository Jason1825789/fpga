`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,//
	parameter BURST_SIZE             = 256,
	parameter WRITE_V_FLIP           = 1,      // 1: vertical flip when writing TF/BMP frame into SDRAM
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    /*
    output                           rd_burst_req,               // to external memory controller,send out a burst read request
	output[BURST_BITS - 1:0]         rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes
	output[ADDR_BITS - 1:0]          rd_burst_addr,              // to external memory controller,base address of the burst read request 
	input                            rd_burst_data_valid,        // from external memory controller,read data valid 
	input[MEM_DATA_BITS - 1:0]       rd_burst_data,              // from external memory controller,read request data
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 //read_data_valid
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,

	input                            read_clk,                   // data read module clock
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	input                            read_en,                    // data read module read request for one data, read_data valid next clock
	output[READ_DATA_BITS  - 1:0]    read_data,                  // read data

	// ===== 第二读通道(转场双读,按需激活) =====
	input                            read2_req,                 // 第二通道读请求(仅转场期间拉高,平时关闭省功耗)
	output                           read2_req_ack,
	output                           read2_finish,
	input[ADDR_BITS - 1:0]           read2_addr_0,
	input[ADDR_BITS - 1:0]           read2_addr_1,
	input[ADDR_BITS - 1:0]           read2_addr_2,
	input[ADDR_BITS - 1:0]           read2_addr_3,
	input[1:0]                       read2_addr_index,
	input[ADDR_BITS - 1:0]           read2_len,
	input                            read2_en,                  // 与 read_en 同步消费
	output[READ_DATA_BITS  - 1:0]    read2_data,                // 第二通道数据
	output                           read_pair_ready,           // read_clk 域:两路 FIFO 均非空
	/*
	output                           wr_burst_req,               // to external memory controller,send out a burst write request
	output[BURST_BITS - 1:0]         wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes
	output[ADDR_BITS - 1:0]          wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock
	output[MEM_DATA_BITS - 1:0]      wr_burst_data,              // to external memory controller,write data
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	//
	input                            write_clk,                  // data write module clock
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output                           write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input                            write_en,                   // data write module write request for one data
	input[WRITE_DATA_BITS - 1:0]     write_data                 // write data

);
wire[8:0]                                        wrusedw;                    // FIFO IP ADDR_WIDTH=9
wire[8:0]                                        rdusedw;                    // FIFO IP ADDR_WIDTH=9

wire 								 App_rd_busy;
wire								 App_wr_busy;

wire                                 read_fifo_aclr;             // fifo Asynchronous clear
wire                                 write_fifo_aclr;            // fifo Asynchronous clear
wire                                 write_fifo_empty;           // 写 FIFO 读侧判空(mem_clk 域)

// 两路读 FIFO 的空标志 + 对齐门控
//
// 两个读 FIFO 用同一个 read_en 抽取,数据必须逐像素一一对应才能正确混合。
// 若其中一路先被抽空(FIFO 内部会停住不推进),另一路照常推进,
// 两路就会永久错开一个像素 → 转场时出现横向重影 / 图像横向错位。
// 因此转场期间(两路都在读)只要有一路空,就把两路一起暂停,保持严格对齐。
//   read2_en 只在交叉淡化 RUN 时有效;其余模式主通道仍按 read_en 读取。
wire                                 rd1_empty;
wire                                 rd2_empty;
wire                                 pair_ready = ~(rd1_empty | rd2_empty);
wire                                 read_en_g = read_en & (~read2_en | pair_ready);
wire                                 read2_en_g = read_en & read2_en & pair_ready;
assign read_pair_ready = pair_ready; // 只导出已有状态,不改变原 FIFO/仲裁逻辑

// 双读仲裁内部线
wire                                 rd1_we;         // ch1 FIFO 写使能(仲裁后)
wire                                 rd2_we;         // ch2 FIFO 写使能
wire                                 rd1_app_en;     // ch1 读请求
wire [ADDR_BITS - 1:0]               rd1_app_addr;
wire                                 rd2_app_en;     // ch2 读请求
wire [ADDR_BITS - 1:0]               rd2_app_addr;
// 仲裁"被服务"指示:分别作为两个读通道的计数 ack(fifo_read 按被服务次数计数,而非发出请求次数)
wire                                 rd1_served;
wire                                 rd2_served;


wire O_wr_busy;
wire O_rd_busy;
wire O_rd_busy2;

assign App_wr_busy = O_wr_busy;//下个时钟写指令拉高
assign App_rd_busy = O_rd_busy | O_rd_busy2;//任一显示读通道在突发期间,禁止写通道插入
assign App_wr_dm = 4'b0000;

//instantiate an asynchronous FIFO 
wfifo_32_32_512 write_buf
	(
	.clkr                      	(mem_clk                  ),          // Read side clock
	.clkw                      	(write_clk                ),          // Write side clock
	.rst                       	(write_fifo_aclr          ),          // Asynchronous clear
	.we                      	(write_en                 ),          // Write Request
	.re                      	(App_wr_en        		  ),          // Read Request
	.di                       	(write_data               ),          // Input Data
	.empty_flag                 (write_fifo_empty         ),          // Read side Empty flag
	.full_flag                  (                         ),          // Write side Full flag
	.wrusedw                	(              	  		  ),          // Read Used Words
	.rdusedw                	(rdusedw                  ),          // Write Used Words
	.dout                       (App_wr_din		          )
);

frame_fifo_write
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               ),
	.WRITE_V_FLIP               (WRITE_V_FLIP             ),
	.FRAME_WIDTH                (FRAME_WIDTH              ),
	.FRAME_HEIGHT               (FRAME_HEIGHT             )
) 
frame_fifo_write_m0              
(  
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
	.App_rd_busy				(App_rd_busy),
    .O_wr_busy					(O_wr_busy),
	
	.App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
	.write_req                  (write_req                ),
	.write_req_ack              (write_req_ack            ),
	.write_finish               (write_finish             ),
	.write_addr_0               (write_addr_0             ),
	.write_addr_1               (write_addr_1             ),
	.write_addr_2               (write_addr_2             ),
	.write_addr_3               (write_addr_3             ),
	.write_addr_index           (write_addr_index         ),    
	.write_len                  (write_len                ),
	.fifo_aclr                  (write_fifo_aclr          ),
	.rdusedw                 	(rdusedw                  ),
	.write_fifo_empty          (write_fifo_empty          )
);

//instantiate an asynchronous FIFO 
rfifo_32_32_512 read_buf
	(
	.clkr                     	(read_clk                   ),          // Read side clock
	.clkw                     	(mem_clk                    ),          // Write side clock
	.rst                      	(read_fifo_aclr             ),          // Asynchronous clear
	.we                     	(rd1_we       			),          // Write Request
	.re                     	(read_en_g                 ),          // Read Request(转场期间两路对齐门控)
	.di                      	(Sdr_rd_dout                ),          // Input Data
	.empty_flag					(rd1_empty                 ),          // Read side Empty flag
	.full_flag					(                           ),          // Write side Full flag
	.wrusedw                	(wrusedw         	  	  		 ),          // Read Used Words
	.rdusedw                	(                  			 ),          // Write Used Words
	.dout						(read_data                  )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(rd1_we),
	.App_rd_ack					(rd1_served),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy),
	
    .App_rd_en					(rd1_app_en),
    .App_rd_addr				(rd1_app_addr),
	.read_req                   (read_req                 ),
	.read_req_ack               (read_req_ack             ),
	.read_finish                (read_finish              ),
	.read_addr_0                (read_addr_0              ),
	.read_addr_1                (read_addr_1              ),
	.read_addr_2                (read_addr_2              ),
	.read_addr_3                (read_addr_3              ),
	.read_addr_index            (read_addr_index          ),    
	.read_len                   (read_len                 ),
	.fifo_aclr                  (read_fifo_aclr           ),
	.wrusedw                	(wrusedw                  )
);

//====================================================
// 第二读通道(转场双读,read2_req 仅在转场期间拉高 = 按需激活省功耗)
//====================================================
wire[8:0]                           rd2usedw;
wire                                read2_fifo_aclr;

rfifo_32_32_512 read2_buf
	(
	.clkr                     	(read_clk                   ),
	.clkw                     	(mem_clk                    ),
	.rst                      	(read2_fifo_aclr            ),
	.we                     	(rd2_we        			    ),
	.re                     	(read2_en_g                 ),
	.di                      	(Sdr_rd_dout                ),
	.empty_flag					(rd2_empty                  ),
	.full_flag					(                           ),
	.wrusedw                	(rd2usedw         	  	    ),
	.rdusedw                	(                  			),
	.dout						(read2_data                 )
);

frame_fifo_read
#
(
	.MEM_DATA_BITS              (MEM_DATA_BITS            ),
	.ADDR_BITS                  (ADDR_BITS                ),
	.BURST_BITS                 (BURST_BITS               ),
	.BURST_SIZE                 (BURST_SIZE               )
)
frame_fifo_read2_m0
(
	.rst                        (rst                      ),
	.mem_clk                    (mem_clk                  ),
    .Sdr_init_done				(Sdr_init_done),
	.Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    .Sdr_rd_en					(rd2_we),
	.App_rd_ack					(rd2_served),
	.App_wr_busy				(App_wr_busy),
    .O_rd_busy					(O_rd_busy2),

    .App_rd_en					(rd2_app_en),
    .App_rd_addr				(rd2_app_addr),
	.read_req                   (read2_req                ),
	.read_req_ack               (read2_req_ack            ),
	.read_finish                (read2_finish             ),
	.read_addr_0                (read2_addr_0             ),
	.read_addr_1                (read2_addr_1             ),
	.read_addr_2                (read2_addr_2             ),
	.read_addr_3                (read2_addr_3             ),
	.read_addr_index            (read2_addr_index         ),
	.read_len                   (read2_len                ),
	.fifo_aclr                  (read2_fifo_aclr          ),
	.wrusedw                	(rd2usedw                 )
);

//====================================================
// 双读仲裁(字级):两通道同时请求时轮换,单通道请求时独占
// 数据回送:请求-响应配对准队列(与读延迟解耦)路由到对应 FIFO
//====================================================
localparam TAG_DEPTH = 64;      // 标签队列深度(与下方 tag_bits 一致)

reg [TAG_DEPTH-1:0] tag_bits;   // 队列内容:1 = ch2(新图/备用缓冲), 0 = ch1(当前显示缓冲)
reg [5:0]           tag_wptr;   // 入队指针
reg [5:0]           tag_rptr;   // 出队指针
reg                 tag_head;   // 当前队首标签的寄存副本，切断 64:1 读选择器到 FIFO 写使能的长路径
reg [6:0]           tag_count;  // 0..64；避免每拍用两个指针做 6 位减法

// 在途请求过多时暂停发请求:避免标签队列溢出导致"标签-数据"永久失配。
//
// tag_count 在每次实际发出请求时加一、每次有效返回时减一，直接表示在途数。
// 这样既避免指针回绕时的占用计算歧义，也切断“指针减法 -> tag_room -> 仲裁”
// 的组合路径。阈值 56 为 64 项队列保留 8 项余量。
wire       tag_room = (tag_count < 7'd56);   // 留 8 项余量,仅在异常积压时背压
wire       tag_empty = (tag_count == 7'd0);
wire       tag_push = rd1_served | rd2_served;
wire       tag_pop  = Sdr_rd_en & ~tag_empty;
wire [5:0] tag_next_rptr = tag_rptr + 6'd1;

reg                                 rd_last;       // 1 = 上次服务了 ch1
always @(posedge mem_clk or posedge rst) begin
    if (rst)
        rd_last <= 1'b0;
    else if (rd1_served)
        rd_last <= 1'b1;
    else if (rd2_served)
        rd_last <= 1'b0;
end

// Sdr_busy=1 时控制器不接受新命令。只有真正送入 SDRAM 的请求才产生 ack、
// 递增地址并压入标签队列，否则刷新碰上读请求会造成地址/返回数据错位。
wire sdram_cmd_ready = Sdr_init_done & ~Sdr_busy;
assign rd1_served = sdram_cmd_ready & tag_room & rd1_app_en & (~rd2_app_en | ~rd_last);
assign rd2_served = sdram_cmd_ready & tag_room & rd2_app_en & ~rd1_served;

assign App_rd_en   = rd1_served | rd2_served;
assign App_rd_addr = rd2_served ? rd2_app_addr : rd1_app_addr;

//====================================================
// 数据回送路由:请求-响应配对准队列(与读延迟解耦)
//
// 为什么不用固定延迟:本设计 SDRAM 控制器开启了自刷新(self_refresh_open=1),
// 刷新期间读请求会被插入等待,读延迟不是恒定值。若按"请求发出后固定 N 拍返回"
// 去路由数据,一旦实际延迟变化,数据就会被写错 FIFO 或整字丢弃 → 图像拉伸/撕裂。
//
// 做法:每个发出的请求(rd1_served|rd2_served)把通道号压入队尾;
//       每拍数据有效(Sdr_rd_en)从队首弹出,决定这一拍数据写进哪个 FIFO。
//       只要"每个请求恰好对应一次数据返回且顺序一致",无论延迟多少拍都正确。
// 深度 64 覆盖"在途请求数 = 读延迟 + 刷新抖动",足够安全。
//====================================================
always @(posedge mem_clk or posedge rst) begin
    if (rst)
        tag_wptr <= 6'd0;
    else if (tag_push)
        tag_wptr <= tag_wptr + 6'd1;
end

always @(posedge mem_clk or posedge rst) begin
    if (rst)
        tag_rptr <= 6'd0;
    else if (tag_pop)
        tag_rptr <= tag_rptr + 6'd1;
end

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        tag_count <= 7'd0;
    end else begin
        case ({tag_push, tag_pop})
            2'b10: tag_count <= tag_count + 7'd1;
            2'b01: tag_count <= tag_count - 7'd1;
            default: tag_count <= tag_count;
        endcase
    end
end

always @(posedge mem_clk) begin
    if (tag_push)
        tag_bits[tag_wptr[5:0]] <= rd2_served;   // 本拍请求的通道号写入队尾
end

// tag_bits[tag_rptr] 的动态 64:1 选择原来直接组合驱动两个异步 FIFO 的写使能。
// 当前布局布线实测该路径最差 -1.178 ns；时序失败时会把返回字写入错误通道，
// 随后读 FIFO 欠载，正好表现为画面停住或像素错位。tag_head 始终提前保存队首，
// 返回数据当拍只经过一个寄存位和空判断。弹出时并行预取下一个队首；当队列仅
// 有一项且同拍一进一出时直接旁路新标签，保持连续返回不插空拍。
always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        tag_head <= 1'b0;
    end else if (tag_pop) begin
        if (tag_count > 7'd1)
            tag_head <= tag_bits[tag_next_rptr];
        else if (tag_push)
            tag_head <= rd2_served;
        else
            tag_head <= 1'b0;
    end else if (tag_push && tag_empty) begin
        tag_head <= rd2_served;
    end
end

wire rd2_now = tag_head;

assign rd1_we = Sdr_rd_en & ~tag_empty & ~rd2_now;
assign rd2_we = Sdr_rd_en & ~tag_empty &  rd2_now;

endmodule
