module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [3:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [3:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // 加载完成标志（电平，非单拍脉冲）：源图数据全部读完、本模块回到 ST_IDLE 后
    // 保持 1，直到下一次 load_start 才清 0。用"电平"而非"脉冲"是为了让上层
    // sd_card_bmp 的 source_done_seen 能在 write_finish_pulse（也是单拍）到达前
    // 稳定置 1 —— 否则两个单拍脉冲存在同拍竞争，会漏判导致首图/预取提交失败。
    output reg                  load_done
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

// 单张图加载超时保护：2 秒 @100MHz 未完成 → 强制回 IDLE（防连按/读卡异常卡死）
localparam LOAD_TIMEOUT_CYCLES = 32'd200_000_000;

// 扫描提前收敛：已找到图之后，连续 SCAN_STALL_SECTORS 个扇区无新图即结束扫描。
// 否则卡内图片少于 scan_target_count 时会把整个 SCAN_MAX_SECTOR 扫完，
// 期间 scan_done 一直为 0，表现为按键长时间不响应。
localparam [31:0] SCAN_STALL_SECTORS = 32'd16384;   // 16384 扇区 = 8MB

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] last_found_sector;
reg        found_any;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

wire header_match;
wire bmp_data_valid;
reg  [31:0] file_sector_count_r;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign ready = (state == ST_IDLE);
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (width[15:0]  == bmp_width) &&
                      (height[15:0] == bmp_height) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
// file_len 原先直接经过“+511、右移、扫描地址加法、边界比较”进入状态机，
// 最新默认布局的实际路径为 9 级逻辑，setup slack=-0.024ns。BMP 头的
// file_len 在第 6 个字节后已经完整，距离 512 字节扇区结束还有数百拍，
// 因此提前寄存扇区数不会增加扫描等待，并切断 file_len 到状态寄存器的长链。
assign next_scan_sector_if_match = scan_sector + file_sector_count_r;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        file_sector_count_r <= 32'd1;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        // rd_cnt==6 时，file_len[31:24] 已在上一拍写入。下面的等价取整
        // ceil(file_len/512) 只在头部阶段计算一次，之后供扫描状态机使用。
        if (rd_cnt == 10'd6) begin
            if (file_len == 32'd0)
                file_sector_count_r <= 32'd1;
            else
                file_sector_count_r <= {9'd0, file_len[31:9]} +
                                       {{31{1'b0}}, (|file_len[8:0])};
        end
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

reg [31:0] load_timeout_cnt;

always @(posedge clk or posedge rst) begin
    if (rst)
        load_timeout_cnt <= 32'd0;
    else if ((state == ST_LOAD_HDR) || (state == ST_LOAD_WAIT) || (state == ST_LOAD_DATA))
        load_timeout_cnt <= load_timeout_cnt + 32'd1;
    else
        load_timeout_cnt <= 32'd0;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        last_found_sector <= 32'd0;
        found_any         <= 1'b0;
        load_sector_latched <= 32'd0;
        load_done         <= 1'b0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        last_found_sector <= 32'd0;
        found_any         <= 1'b0;
        load_sector_latched <= 32'd0;
        load_done         <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        // load_done 是电平：不复位、不再每拍清 0（否则只保持一拍，退化回脉冲）。
        // 只在 load_start（ST_IDLE 分支）和复位/!sd_init_done 时清 0，完成回 IDLE 时置 1。

        // 加载超时保护：超过 2 秒 → 强制中止回 IDLE（SCAN 阶段不受影响）
        if (((state == ST_LOAD_HDR) || (state == ST_LOAD_WAIT) || (state == ST_LOAD_DATA)) &&
            (load_timeout_cnt >= LOAD_TIMEOUT_CYCLES - 1)) begin
            state        <= ST_IDLE;
            state_code   <= 4'd0;
            sd_sec_read  <= 1'b0;
            write_req    <= 1'b0;
        end else

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done         <= 1'b0;
                    scan_found_total  <= 3'd0;
                    last_found_sector <= scan_start_sector;
                    found_any         <= 1'b0;
                    scan_sector       <= scan_start_sector;
                    sd_sec_read_addr  <= scan_start_sector;
                    state             <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                    load_done           <= 1'b0;   // 发起新加载，清完成标志
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;
                        last_found_sector <= scan_sector;
                        found_any         <= 1'b1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        // 到上限,或"已找到图但连续长时间无新图" → 结束扫描
                        // (避免卡内图片不足 scan_target_count 时长时间扫满,期间按键无响应)
                        if ((scan_sector >= scan_max_sector) ||
                            (found_any && ((scan_sector - last_found_sector) >= SCAN_STALL_SECTORS))) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state     <= ST_IDLE;
                        load_done <= 1'b1;   // 读完最后一字节 → 置完成电平（保持到下次 load_start）
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
