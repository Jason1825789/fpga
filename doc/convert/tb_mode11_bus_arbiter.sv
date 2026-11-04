`timescale 1ns/1ps

module tb_mode11_bus_arbiter;
    reg mem_clk=0, read_clk=0, write_clk=0, rst=1;
    always #4 mem_clk=~mem_clk;       // 125 MHz
    always #20 read_clk=~read_clk;    // 25 MHz
    always #5 write_clk=~write_clk;   // 100 MHz

    reg init_done=0;
    reg sdr_busy=0;
    reg [31:0] busy_ctr=0;
    always @(posedge mem_clk) begin
        if (rst) begin busy_ctr<=0; sdr_busy<=0; end
        else begin
            busy_ctr<=busy_ctr+1;
            // Periodic refresh/service blackout.
            sdr_busy <= ((busy_ctr%41)>=29 && (busy_ctr%41)<=31);
        end
    end

    reg read_req=0, read2_req=0, read_en=1, read2_en=1;
    reg write_req=0, write_en=0;
    reg [31:0] write_data=0;
    reg [1:0] read_idx=0, read2_idx=1, write_idx=1;
    wire read_ack, read2_ack, write_ack;
    wire [31:0] read_data, read2_data;
    wire read_finish, read2_finish, write_finish;
    wire read_pair_ready;
    wire app_rd_en, app_wr_en;
    wire [20:0] app_rd_addr, app_wr_addr;
    wire [31:0] app_wr_din;
    wire [3:0] app_wr_dm;
    wire [31:0] sdr_rd_dout;
    wire sdr_rd_en;

    frame_read_write #(.ADDR_BITS(21), .BURST_BITS(9), .BURST_SIZE(16),
        .FRAME_WIDTH(8), .FRAME_HEIGHT(4)) dut (
        .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(init_done),
        .Sdr_init_ref_vld(1'b0), .Sdr_busy(sdr_busy),
        .App_rd_en(app_rd_en), .App_rd_addr(app_rd_addr),
        .Sdr_rd_en(sdr_rd_en), .Sdr_rd_dout(sdr_rd_dout),
        .read_clk(read_clk), .read_req(read_req), .read_req_ack(read_ack),
        .read_finish(read_finish),
        .read_addr_0(21'd0), .read_addr_1(21'd4096),
        .read_addr_2(21'd0), .read_addr_3(21'd0),
        .read_addr_index(read_idx), .read_len(21'd4096), .read_en(read_en),
        .read_data(read_data),
        .read2_req(read2_req), .read2_req_ack(read2_ack),
        .read2_finish(read2_finish),
        .read2_addr_0(21'd0), .read2_addr_1(21'd4096),
        .read2_addr_2(21'd0), .read2_addr_3(21'd0),
        .read2_addr_index(read2_idx), .read2_len(21'd4096),
        .read2_en(read2_en), .read2_data(read2_data),
        .read_pair_ready(read_pair_ready),
        .App_wr_en(app_wr_en), .App_wr_addr(app_wr_addr),
        .App_wr_din(app_wr_din), .App_wr_dm(app_wr_dm),
        .write_clk(write_clk), .write_req(write_req),
        .write_req_ack(write_ack), .write_finish(write_finish),
        .write_addr_0(21'd0), .write_addr_1(21'd4096),
        .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(write_idx), .write_len(21'd256),
        .write_en(write_en), .write_data(write_data)
    );

    // SDRAM read model: accepted requests return in order after variable delay.
    reg [20:0] return_addr[0:127];
    reg [7:0] return_wait[0:127];
    integer q_w=0, q_r=0;
    reg [31:0] tick=0;
    reg [31:0] rd_word=0;
    reg rd_valid=0;
    assign sdr_rd_dout=rd_word;
    assign sdr_rd_en=rd_valid;
    always @(posedge mem_clk) begin
        if (rst) begin q_w<=0; q_r<=0; tick<=0; rd_word<=0; rd_valid<=0; end
        else begin
            tick<=tick+1;
            rd_valid<=0;
            if (app_rd_en && !sdr_busy) begin
                return_addr[q_w%128] <= app_rd_addr;
                return_wait[q_w%128] <= 5 + (tick%7);
                q_w<=q_w+1;
            end
            if (q_r<q_w) begin
                if (return_wait[q_r%128]==0) begin
                    rd_word <= {11'd0, return_addr[q_r%128]};
                    rd_valid<=1;
                    q_r<=q_r+1;
                end else return_wait[q_r%128]<=return_wait[q_r%128]-1'b1;
            end
        end
    end

    integer overlap_cycles=0;
    integer overlap_rd2_cycles=0;
    integer rd2_burst_cycles=0;
    integer pass_fd;
    always @(posedge mem_clk) begin
        if (!rst) begin
            if (app_rd_en && app_wr_en) overlap_cycles<=overlap_cycles+1;
            if (dut.frame_fifo_read2_m0.state==4'd3) begin
                rd2_burst_cycles<=rd2_burst_cycles+1;
                if (dut.frame_fifo_write_m0.state==4'd3)
                    overlap_rd2_cycles<=overlap_rd2_cycles+1;
            end
        end
    end

    task automatic send_read_requests;
        begin
            @(negedge read_clk); read_req=1; read2_req=1;
            wait(read_ack && read2_ack);
            @(negedge read_clk); read_req=0; read2_req=0;
        end
    endtask

    task automatic stream_write_frame;
        integer n;
        begin
            @(negedge write_clk); write_req=1;
            wait(write_ack);
            @(negedge write_clk); write_req=0;
            repeat(8) @(negedge write_clk);
            for (n=0;n<256;n=n+1) begin
                write_en=1;
                write_data=32'hA5000000+n;
                @(negedge write_clk);
            end
            write_en=0;
        end
    endtask

    initial begin
        repeat(10) @(negedge mem_clk); rst=0; init_done=1;
        fork
            send_read_requests();
            stream_write_frame();
        join
        repeat(5000) @(negedge mem_clk);
        $display("rd2 burst cycles=%0d, read/write request overlap=%0d, rd2/write burst overlap=%0d",
            rd2_burst_cycles, overlap_cycles, overlap_rd2_cycles);
        if (rd2_burst_cycles==0) $fatal(1,"secondary read never entered a burst");
        if (overlap_cycles!=0 || overlap_rd2_cycles!=0)
            $fatal(1,"write burst overlapped a secondary display read burst");
        pass_fd = $fopen("memory_arbiter.pass", "w");
        $fdisplay(pass_fd, "PASS: dual-read/write SDRAM command exclusion");
        $fclose(pass_fd);
        $display("PASS: dual-read/write SDRAM command exclusion");
        $finish;
    end
endmodule
