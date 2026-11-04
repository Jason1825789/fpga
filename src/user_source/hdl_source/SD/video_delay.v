module video_delay
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input[DATA_WIDTH - 1:0]     read_data2,         // Read data channel 2 (转场双读)
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output[DATA_WIDTH - 1:0]    vout_data,          // video data
	output[DATA_WIDTH - 1:0]    vout_data2          // video data channel 2(转场双读)

);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;
reg[DATA_WIDTH - 1:0]  vout_data2_r;

assign read_en = de_d[18];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vout_data = vout_data_r;
assign vout_data2 = vout_data2_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1) begin
		vout_data_r  <= {DATA_WIDTH{1'b0}};
		vout_data2_r <= {DATA_WIDTH{1'b0}};
	end
	else if(de_d[19]) begin
		vout_data_r  <= read_data;
		vout_data2_r <= read_data2;
	end
	else begin
		vout_data_r  <= {DATA_WIDTH{1'b0}};
		vout_data2_r <= {DATA_WIDTH{1'b0}};
	end
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
		hs_d <= 21'b0;
        vs_d <= 21'b0;
        de_d <= 21'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
        de_d <= {de_d[19:0],de};
    end
end
endmodule
