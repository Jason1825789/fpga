`timescale 1ns/1ps

module tb_mode11_controller;
    localparam [23:0] OLD_PIXEL = 24'h112233;
    localparam [23:0] NEW_PIXEL = 24'hA1B2C3;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg vs = 1'b1;
    reg [1:0] mode_sel = 2'b11;
    reg transition_req = 1'b0;
    reg pixel_pair_ready = 1'b0;
    reg [15:0] pixel_y = 16'd0;
    reg [23:0] old_pixel = OLD_PIXEL;
    reg [23:0] new_pixel = 24'hDEADBE;

    wire prefetch;
    wire consume;
    wire selected;
    wire active;
    wire done;
    wire [1:0] state_dbg;
    wire [23:0] mixed_pixel;

    integer done_count = 0;
    integer i;

    always #20 clk = ~clk;

    mode_11_controller #(
        .MODE_STABLE_CYCLES (20'd2),
        .FRAME_HEIGHT       (10'd8),
        .CURTAIN_STEP       (10'd2),
        .SWITCH_GUARD_FRAMES(3'd4)
    ) dut (
        .clk               (clk),
        .rst               (rst),
        .vs                (vs),
        .mode_sel          (mode_sel),
        .transition_req    (transition_req),
        .pixel_pair_ready  (pixel_pair_ready),
        .pixel_y           (pixel_y),
        .old_pixel         (old_pixel),
        .new_pixel         (new_pixel),
        .read2_prefetch_en (prefetch),
        .read2_consume_en  (consume),
        .mode11_selected   (selected),
        .active            (active),
        .transition_done   (done),
        .state_dbg         (state_dbg),
        .mixed_pixel       (mixed_pixel)
    );

    always @(posedge clk) begin
        #1;
        if (!rst) begin
            if (prefetch !== 1'b0 || consume !== 1'b0)
                $fatal(1, "single-read mode11 enabled channel 2");
            if (mixed_pixel === new_pixel)
                $fatal(1, "unused channel-2 pixel reached the output");
            if (done) begin
                done_count = done_count + 1;
                if (state_dbg !== 2'd3 || mixed_pixel !== 24'h000000)
                    $fatal(1, "transition_done was not issued under full black");
            end
        end
    end

    task automatic frame_boundary;
        begin
            repeat (4) @(negedge clk);
            vs = 1'b0;
            repeat (2) @(negedge clk);
            vs = 1'b1;
            #1;
        end
    endtask

    task automatic expect_pixel;
        input [15:0] y;
        input [23:0] expected;
        begin
            pixel_y = y;
            #1;
            if (mixed_pixel !== expected)
                $fatal(1, "row=%0d got=%h expected=%h state=%0d",
                       y, mixed_pixel, expected, state_dbg);
        end
    endtask

    task automatic expect_all;
        input [23:0] expected;
        integer y;
        begin
            for (y = 0; y < 8; y = y + 1)
                expect_pixel(y[15:0], expected);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        wait (selected === 1'b1);

        transition_req = 1'b1;
        wait (state_dbg == 2'd1);
        expect_all(OLD_PIXEL);

        frame_boundary();
        if (state_dbg !== 2'd2)
            $fatal(1, "9/ARM did not advance to A/RUN");
        expect_all(OLD_PIXEL);

        frame_boundary();
        expect_pixel(16'd0, 24'h000000);
        expect_pixel(16'd1, 24'h000000);
        expect_pixel(16'd2, OLD_PIXEL);
        expect_pixel(16'd5, OLD_PIXEL);
        expect_pixel(16'd6, 24'h000000);
        expect_pixel(16'd7, 24'h000000);

        frame_boundary();
        if (state_dbg !== 2'd3 || done_count != 1)
            $fatal(1, "A/RUN did not close to B/HOLD with one switch pulse");
        expect_all(24'h000000);

        // Model the main channel switching to the new buffer under the curtain.
        old_pixel = NEW_PIXEL;
        for (i = 0; i < 4; i = i + 1) begin
            frame_boundary();
            expect_all(24'h000000);
            if (done_count != 1)
                $fatal(1, "duplicate switch pulse during black guard");
        end

        frame_boundary();
        if (state_dbg !== 2'd3)
            $fatal(1, "opening must retain B/HOLD diagnostic state");
        expect_pixel(16'd0, 24'h000000);
        expect_pixel(16'd1, 24'h000000);
        expect_pixel(16'd2, NEW_PIXEL);
        expect_pixel(16'd5, NEW_PIXEL);
        expect_pixel(16'd6, 24'h000000);
        expect_pixel(16'd7, 24'h000000);

        frame_boundary();
        if (state_dbg !== 2'd0 || active !== 1'b0)
            $fatal(1, "B/HOLD did not return to 0/IDLE");
        expect_all(NEW_PIXEL);

        // A held request must not retrigger until it has first gone low.
        repeat (3) frame_boundary();
        if (state_dbg !== 2'd0 || done_count != 1)
            $fatal(1, "held request retriggered");

        transition_req = 1'b0;
        repeat (3) @(negedge clk);
        transition_req = 1'b1;
        wait (state_dbg == 2'd1);

        $display("PASS: mode11 single-read curtain, 0->9->A->B->0, ch2 disabled");
        $finish;
    end
endmodule
