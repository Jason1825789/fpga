`timescale 1ns/1ns

module fft
(
    input   wire        clk,
    input   wire        rst,
    input   wire        mode, // 0:fft;  1:ifft;
    
    // 时域信号输入
    input   wire        start,
    input   wire        din_en,
    input   wire [15:0] din_re,
    input   wire [15:0] din_im,
    
    // 频域信号输出
    output  reg         done,
    output  reg         busy,
    output  reg         dout_en,
    output  reg [25:0]  dout_re,
    output  reg [25:0]  dout_im
);

`pragma protect begin
localparam W = 16;   // 输入数据位宽; 输出数据位宽 = 输入数据位宽 + log2(N)
localparam N = 1024; // FFT数据长度

reg ren0;
reg ren1;
reg wen0;
reg wen1;
reg [$clog2(N)-1:0] addr0;
reg [$clog2(N)-1:0] addr1;
reg [$clog2(N)-1:0] addr2;
reg [$clog2(N)-1:0] addr3;
reg [$clog2(N)-1:0] addr4;
reg [1:0] phase0;
reg [1:0] phase1;
reg spoint;
reg data_en;
reg [W-1:0] data_re;
reg [W-1:0] data_im;
reg [W+$clog2(N)-1:0] real0;
reg [W+$clog2(N)-1:0] imag0;
reg [W+$clog2(N)-1:0] real1;
reg [W+$clog2(N)-1:0] imag1;
reg [W-1:0] real2;
reg [W-1:0] imag2;
wire [W-1:0] real3;
wire [W-1:0] imag3;
reg [W+$clog2(N)-1:0] real4;
reg [W+$clog2(N)-1:0] imag4;
reg [W-1:0] real5;
reg [W-1:0] imag5;
reg [W+$clog2(N)-1:0] real6;
reg [W+$clog2(N)-1:0] imag6;
reg [2*W+$clog2(N)-1:0] real7;
reg [2*W+$clog2(N)-1:0] imag7;
reg [2*W+$clog2(N)-1:0] real8;
reg [2*W+$clog2(N)-1:0] imag8;
reg [W+$clog2(N)-1:0] real9;
reg [W+$clog2(N)-1:0] imag9;
reg [W+$clog2(N)-1:0] real10;
reg [W+$clog2(N)-1:0] imag10;
reg [W+$clog2(N)-1:0] real11;
reg [W+$clog2(N)-1:0] imag11;
reg [W+$clog2(N)-1:0] real12;
reg [W+$clog2(N)-1:0] imag12;
reg [W+$clog2(N)-1:0] real13;
reg [W+$clog2(N)-1:0] imag13;
reg [W+$clog2(N)-1:0] real14;
reg [W+$clog2(N)-1:0] imag14;
reg [W+$clog2(N)-1:0] real15;
reg [W+$clog2(N)-1:0] imag15;
reg [W+$clog2(N)-1:0] real16;
reg [W+$clog2(N)-1:0] imag16;
reg [W+$clog2(N)-1:0] real17;
reg [W+$clog2(N)-1:0] imag17;
reg [2*W+2*$clog2(N)-1:0] wdata0;
reg [2*W+2*$clog2(N)-1:0] wdata1;
reg [2*W+2*$clog2(N)-1:0] rdata0;
reg [2*W+2*$clog2(N)-1:0] rdata1;
reg [$clog2($clog2(N))-1:0] k;
reg [$clog2(N):0] n;
wire [$clog2(N)-1:0] ni;
reg [$clog2(N)-1:0] m;
reg [$clog2(N)-1:0] mm;
reg [$clog2(N)-3:0] nmax;
reg [$clog2(N)-2:0] mmax;
reg [$clog2(N)-1:0] bstep;
reg [$clog2(N)-1:0] base0;
reg [$clog2(N)-1:0] base1;
reg [$clog2(N)-1:0] offset;
reg [W-1:0] rom[0:N/4-1]; // synthesis ram_style = bram
reg [2*W+2*$clog2(N)-1:0] ram[0:N-1]; // synthesis ram_style = bram

wire _ctrl0_;
wire _ctrl1_;
wire _ctrl2_;
wire _ctrl3_;
wire _ctrl4_;
wire _ctrl5_;
wire _ctrl6_;
wire _ctrl7_;
wire _ctrl8_;
wire _ctrl9_;
wire _ctrl10_;
wire _ctrl11_;
wire _ctrl12_;
wire _ctrl13_;
wire _ctrl14_;
wire _ctrl15_;
wire _ctrl16_;
wire _ctrl17_;
wire _ctrl18_;
wire _ctrl19_;
wire _ctrl20_;
wire _ctrl21_;
wire _ctrl22_;
wire _ctrl23_;
wire _ctrl24_;
wire _ctrl25_;
wire _ctrl26_;
wire _ctrl27_;
wire _ctrl28_;
wire _ctrl29_;
wire _ctrl30_;
wire _ctrl31_;
wire _ctrl32_;
wire _ctrl33_;
reg _ctrl34_;
wire _ctrl35_;
wire _ctrl36_;
wire _ctrl37_;
reg _ctrl38_;
reg _ctrl39_;
reg _ctrl40_;
reg _ctrl41_;
reg _ctrl42_;
reg _ctrl43_;
reg _ctrl44_;
reg _ctrl45_;
reg _ctrl46_;
reg _ctrl47_;
reg _ctrl48_;
reg _ctrl49_;
reg _ctrl50_;
reg _ctrl51_;
reg _ctrl52_;
reg _ctrl53_;
reg _ctrl54_;
reg _ctrl55_;
reg _ctrl56_;
reg _ctrl57_;
reg _ctrl58_;
reg _ctrl59_;
reg _ctrl60_;
reg _ctrl61_;
reg _ctrl62_;
reg _ctrl63_;
reg _ctrl64_;
reg _ctrl65_;
reg _ctrl66_;
reg _ctrl67_;
reg _ctrl68_;
reg _ctrl69_;
reg _ctrl70_;
reg _ctrl71_;
reg _ctrl72_;
reg _ctrl73_;
reg _ctrl74_;
reg _ctrl75_;
reg _ctrl76_;
reg _ctrl77_;
reg _ctrl78_;
reg _ctrl79_;
reg _ctrl80_;
reg _ctrl81_;
reg _ctrl82_;
reg _ctrl83_;
reg _ctrl84_;
reg _ctrl85_;
reg _ctrl86_;
reg _ctrl87_;
reg _ctrl88_;
reg _ctrl89_;
reg _ctrl90_;
reg _ctrl91_;
reg _ctrl92_;
reg _ctrl93_;
reg _ctrl94_;
reg _ctrl95_;
reg _ctrl96_;
reg _ctrl97_;
reg _ctrl98_;
reg _ctrl99_;
reg _ctrl100_;
reg _ctrl101_;
reg _ctrl102_;
reg _ctrl103_;
reg _ctrl104_;
reg _ctrl105_;
reg _ctrl106_;
reg _ctrl107_;
reg _ctrl108_;
reg _ctrl109_;
reg _ctrl110_;
reg _ctrl111_;
reg _ctrl112_;
reg _ctrl113_;
reg _ctrl114_;
reg _ctrl115_;
reg _ctrl116_;
reg _ctrl117_;
reg _ctrl118_;
reg _ctrl119_;
reg _ctrl120_;
reg _ctrl121_;
reg _ctrl122_;
wire _ctrl123_;
wire _ctrl124_;
wire _ctrl125_;
wire _ctrl126_;
wire _ctrl127_;
wire _ctrl128_;
wire _ctrl129_;
wire _ctrl130_;
wire _ctrl131_;
wire _ctrl132_;
wire _ctrl133_;
wire _ctrl134_;
wire _ctrl135_;
wire _ctrl136_;
wire _ctrl137_;
wire _ctrl138_;
wire _ctrl139_;
wire _ctrl140_;
wire _ctrl141_;
reg _ctrl142_;
reg _ctrl143_;
reg _ctrl144_;
reg _ctrl145_;
reg _ctrl146_;

wire _ctrl147_;
wire _ctrl148_;
wire _ctrl149_;
wire _ctrl150_;
wire _ctrl151_;
wire _ctrl152_;
wire _ctrl153_;
wire _ctrl154_;
wire _ctrl155_;
wire _ctrl156_;
wire _ctrl157_;
wire _ctrl158_;
wire _ctrl159_;
wire _ctrl160_;
wire _ctrl161_;
wire _ctrl162_;
wire _ctrl163_;
wire _ctrl164_;
wire _ctrl165_;
wire _ctrl166_;
wire _ctrl167_;
wire _ctrl168_;
wire _ctrl169_;
wire _ctrl170_;
wire _ctrl171_;
wire _ctrl172_;
wire _ctrl173_;
wire _ctrl174_;
wire _ctrl175_;
wire _ctrl176_;
wire _ctrl177_;
wire _ctrl178_;
wire _ctrl179_;
wire _ctrl180_;
wire _ctrl181_;
wire _ctrl182_;
wire _ctrl183_;
wire _ctrl184_;
wire _ctrl185_;
wire _ctrl186_;
wire _ctrl187_;
wire _ctrl188_;
wire _ctrl189_;
wire _ctrl190_;
wire _ctrl191_;
wire _ctrl192_;
wire _ctrl193_;
wire _ctrl194_;
wire _ctrl195_;
wire _ctrl196_;
wire _ctrl197_;
wire _ctrl198_;
wire _ctrl199_;
wire _ctrl200_;
wire _ctrl201_;
wire _ctrl202_;
wire _ctrl203_;
wire _ctrl204_;
wire _ctrl205_;
wire _ctrl206_;
wire _ctrl207_;
wire _ctrl208_;
wire _ctrl209_;
reg _ctrl210_;
reg _ctrl211_;
reg _ctrl212_;
reg _ctrl213_;
reg _ctrl214_;
reg _ctrl215_;
reg _ctrl216_;
reg _ctrl217_;
reg _ctrl218_;
reg _ctrl219_;
reg _ctrl220_;
reg _ctrl221_;
reg _ctrl222_;
reg _ctrl223_;
reg _ctrl224_;
reg _ctrl225_;
wire _ctrl226_;
wire _ctrl227_;
wire _ctrl228_;
wire _ctrl229_;
wire _ctrl230_;
wire _ctrl231_;
wire _ctrl232_;
wire _ctrl233_;
wire _ctrl234_;
wire _ctrl235_;
wire _ctrl236_;
wire _ctrl237_;
wire _ctrl238_;
reg _ctrl239_;
wire _ctrl240_;
wire _ctrl241_;
wire _ctrl242_;
reg _ctrl243_;
wire _ctrl244_;
wire _ctrl245_;
wire _ctrl246_;
reg _ctrl247_;
reg _ctrl248_;
wire _ctrl249_;
reg _ctrl250_;
reg _ctrl251_;

initial
begin
    done = 0;
    busy = 0;
    dout_en = 0;
    dout_re = 0;
    dout_im = 0;
    ren0 = 0;
    ren1 = 0;
    wen0 = 0;
    wen1 = 0;
    addr0 = 0;
    addr1 = 0;
    addr2 = 0;
    addr3 = 0;
    addr4 = 0;
    phase0 = 0;
    phase1 = 0;
    spoint = 0;
    data_en = 0;
    data_re = 0;
    data_im = 0;
    real0 = 0;
    imag0 = 0;
    real1 = 0;
    imag1 = 0;
    real2 = 0;
    imag2 = 0;
    real4 = 0;
    imag4 = 0;
    real5 = 0;
    imag5 = 0;
    real6 = 0;
    imag6 = 0;
    real7 = 0;
    imag7 = 0;
    real8 = 0;
    imag8 = 0;
    real9 = 0;
    imag9 = 0;
    real10 = 0;
    imag10 = 0;
    real11 = 0;
    imag11 = 0;
    real12 = 0;
    imag12 = 0;
    real13 = 0;
    imag13 = 0;
    real14 = 0;
    imag14 = 0;
    real15 = 0;
    imag15 = 0;
    real16 = 0;
    imag16 = 0;
    real17 = 0;
    imag17 = 0;
    wdata0 = 0;
    wdata1 = 0;
    rdata0 = 0;
    rdata1 = 0;
    k = 0;
    n = 0;
    m = 0;
    mm = 0;
    nmax = 0;
    mmax = 0;
    bstep = 0;
    base0 = 0;
    base1 = 0;
    offset = 0;
    _ctrl34_ = 0;
    _ctrl38_ = 0;
    _ctrl39_ = 0;
    _ctrl40_ = 0;
    _ctrl41_ = 0;
    _ctrl42_ = 0;
    _ctrl43_ = 0;
    _ctrl44_ = 0;
    _ctrl45_ = 0;
    _ctrl46_ = 0;
    _ctrl47_ = 0;
    _ctrl48_ = 0;
    _ctrl49_ = 0;
    _ctrl50_ = 0;
    _ctrl51_ = 0;
    _ctrl52_ = 0;
    _ctrl53_ = 0;
    _ctrl54_ = 0;
    _ctrl55_ = 0;
    _ctrl56_ = 0;
    _ctrl57_ = 0;
    _ctrl58_ = 0;
    _ctrl59_ = 0;
    _ctrl60_ = 0;
    _ctrl61_ = 0;
    _ctrl62_ = 0;
    _ctrl63_ = 0;
    _ctrl64_ = 0;
    _ctrl65_ = 0;
    _ctrl66_ = 0;
    _ctrl67_ = 0;
    _ctrl68_ = 0;
    _ctrl69_ = 0;
    _ctrl70_ = 0;
    _ctrl71_ = 0;
    _ctrl72_ = 0;
    _ctrl73_ = 0;
    _ctrl74_ = 0;
    _ctrl75_ = 0;
    _ctrl76_ = 0;
    _ctrl77_ = 0;
    _ctrl78_ = 0;
    _ctrl79_ = 0;
    _ctrl80_ = 0;
    _ctrl81_ = 0;
    _ctrl82_ = 0;
    _ctrl83_ = 0;
    _ctrl84_ = 0;
    _ctrl85_ = 0;
    _ctrl86_ = 0;
    _ctrl87_ = 0;
    _ctrl88_ = 0;
    _ctrl89_ = 0;
    _ctrl90_ = 0;
    _ctrl91_ = 0;
    _ctrl92_ = 0;
    _ctrl93_ = 0;
    _ctrl94_ = 0;
    _ctrl95_ = 0;
    _ctrl96_ = 0;
    _ctrl97_ = 0;
    _ctrl98_ = 0;
    _ctrl99_ = 0;
    _ctrl100_ = 0;
    _ctrl101_ = 0;
    _ctrl102_ = 0;
    _ctrl103_ = 0;
    _ctrl104_ = 0;
    _ctrl105_ = 0;
    _ctrl106_ = 0;
    _ctrl107_ = 0;
    _ctrl108_ = 0;
    _ctrl109_ = 0;
    _ctrl110_ = 0;
    _ctrl111_ = 0;
    _ctrl112_ = 0;
    _ctrl113_ = 0;
    _ctrl114_ = 0;
    _ctrl115_ = 0;
    _ctrl116_ = 0;
    _ctrl117_ = 0;
    _ctrl118_ = 0;
    _ctrl119_ = 0;
    _ctrl120_ = 0;
    _ctrl121_ = 0;
    _ctrl122_ = 0;
    _ctrl142_ = 0;
    _ctrl143_ = 0;
    _ctrl144_ = 0;
    _ctrl145_ = 0;
    _ctrl146_ = 0;
    _ctrl210_ = 0;
    _ctrl211_ = 0;
    _ctrl212_ = 0;
    _ctrl213_ = 0;
    _ctrl214_ = 0;
    _ctrl215_ = 0;
    _ctrl216_ = 0;
    _ctrl217_ = 0;
    _ctrl218_ = 0;
    _ctrl219_ = 0;
    _ctrl220_ = 0;
    _ctrl221_ = 0;
    _ctrl222_ = 0;
    _ctrl223_ = 0;
    _ctrl224_ = 0;
    _ctrl225_ = 0;
    _ctrl239_ = 0;
    _ctrl243_ = 0;
    _ctrl247_ = 0;
    _ctrl248_ = 0;
    _ctrl250_ = 0;
    _ctrl251_ = 0;
end

// sin函数表: rom[I] = round(sin(2*pi*I/N)*(2^(WI-1)-1));
initial
begin
    rom[0] = 16'd0;
    rom[1] = 16'd201;
    rom[2] = 16'd402;
    rom[3] = 16'd603;
    rom[4] = 16'd804;
    rom[5] = 16'd1005;
    rom[6] = 16'd1206;
    rom[7] = 16'd1407;
    rom[8] = 16'd1608;
    rom[9] = 16'd1809;
    rom[10] = 16'd2009;
    rom[11] = 16'd2210;
    rom[12] = 16'd2410;
    rom[13] = 16'd2611;
    rom[14] = 16'd2811;
    rom[15] = 16'd3012;
    rom[16] = 16'd3212;
    rom[17] = 16'd3412;
    rom[18] = 16'd3612;
    rom[19] = 16'd3811;
    rom[20] = 16'd4011;
    rom[21] = 16'd4210;
    rom[22] = 16'd4410;
    rom[23] = 16'd4609;
    rom[24] = 16'd4808;
    rom[25] = 16'd5007;
    rom[26] = 16'd5205;
    rom[27] = 16'd5404;
    rom[28] = 16'd5602;
    rom[29] = 16'd5800;
    rom[30] = 16'd5998;
    rom[31] = 16'd6195;
    rom[32] = 16'd6393;
    rom[33] = 16'd6590;
    rom[34] = 16'd6786;
    rom[35] = 16'd6983;
    rom[36] = 16'd7179;
    rom[37] = 16'd7375;
    rom[38] = 16'd7571;
    rom[39] = 16'd7767;
    rom[40] = 16'd7962;
    rom[41] = 16'd8157;
    rom[42] = 16'd8351;
    rom[43] = 16'd8545;
    rom[44] = 16'd8739;
    rom[45] = 16'd8933;
    rom[46] = 16'd9126;
    rom[47] = 16'd9319;
    rom[48] = 16'd9512;
    rom[49] = 16'd9704;
    rom[50] = 16'd9896;
    rom[51] = 16'd10087;
    rom[52] = 16'd10278;
    rom[53] = 16'd10469;
    rom[54] = 16'd10659;
    rom[55] = 16'd10849;
    rom[56] = 16'd11039;
    rom[57] = 16'd11228;
    rom[58] = 16'd11417;
    rom[59] = 16'd11605;
    rom[60] = 16'd11793;
    rom[61] = 16'd11980;
    rom[62] = 16'd12167;
    rom[63] = 16'd12353;
    rom[64] = 16'd12539;
    rom[65] = 16'd12725;
    rom[66] = 16'd12910;
    rom[67] = 16'd13094;
    rom[68] = 16'd13279;
    rom[69] = 16'd13462;
    rom[70] = 16'd13645;
    rom[71] = 16'd13828;
    rom[72] = 16'd14010;
    rom[73] = 16'd14191;
    rom[74] = 16'd14372;
    rom[75] = 16'd14553;
    rom[76] = 16'd14732;
    rom[77] = 16'd14912;
    rom[78] = 16'd15090;
    rom[79] = 16'd15269;
    rom[80] = 16'd15446;
    rom[81] = 16'd15623;
    rom[82] = 16'd15800;
    rom[83] = 16'd15976;
    rom[84] = 16'd16151;
    rom[85] = 16'd16325;
    rom[86] = 16'd16499;
    rom[87] = 16'd16673;
    rom[88] = 16'd16846;
    rom[89] = 16'd17018;
    rom[90] = 16'd17189;
    rom[91] = 16'd17360;
    rom[92] = 16'd17530;
    rom[93] = 16'd17700;
    rom[94] = 16'd17869;
    rom[95] = 16'd18037;
    rom[96] = 16'd18204;
    rom[97] = 16'd18371;
    rom[98] = 16'd18537;
    rom[99] = 16'd18703;
    rom[100] = 16'd18868;
    rom[101] = 16'd19032;
    rom[102] = 16'd19195;
    rom[103] = 16'd19357;
    rom[104] = 16'd19519;
    rom[105] = 16'd19680;
    rom[106] = 16'd19841;
    rom[107] = 16'd20000;
    rom[108] = 16'd20159;
    rom[109] = 16'd20317;
    rom[110] = 16'd20475;
    rom[111] = 16'd20631;
    rom[112] = 16'd20787;
    rom[113] = 16'd20942;
    rom[114] = 16'd21096;
    rom[115] = 16'd21250;
    rom[116] = 16'd21403;
    rom[117] = 16'd21554;
    rom[118] = 16'd21705;
    rom[119] = 16'd21856;
    rom[120] = 16'd22005;
    rom[121] = 16'd22154;
    rom[122] = 16'd22301;
    rom[123] = 16'd22448;
    rom[124] = 16'd22594;
    rom[125] = 16'd22739;
    rom[126] = 16'd22884;
    rom[127] = 16'd23027;
    rom[128] = 16'd23170;
    rom[129] = 16'd23311;
    rom[130] = 16'd23452;
    rom[131] = 16'd23592;
    rom[132] = 16'd23731;
    rom[133] = 16'd23870;
    rom[134] = 16'd24007;
    rom[135] = 16'd24143;
    rom[136] = 16'd24279;
    rom[137] = 16'd24413;
    rom[138] = 16'd24547;
    rom[139] = 16'd24680;
    rom[140] = 16'd24811;
    rom[141] = 16'd24942;
    rom[142] = 16'd25072;
    rom[143] = 16'd25201;
    rom[144] = 16'd25329;
    rom[145] = 16'd25456;
    rom[146] = 16'd25582;
    rom[147] = 16'd25708;
    rom[148] = 16'd25832;
    rom[149] = 16'd25955;
    rom[150] = 16'd26077;
    rom[151] = 16'd26198;
    rom[152] = 16'd26319;
    rom[153] = 16'd26438;
    rom[154] = 16'd26556;
    rom[155] = 16'd26674;
    rom[156] = 16'd26790;
    rom[157] = 16'd26905;
    rom[158] = 16'd27019;
    rom[159] = 16'd27133;
    rom[160] = 16'd27245;
    rom[161] = 16'd27356;
    rom[162] = 16'd27466;
    rom[163] = 16'd27575;
    rom[164] = 16'd27683;
    rom[165] = 16'd27790;
    rom[166] = 16'd27896;
    rom[167] = 16'd28001;
    rom[168] = 16'd28105;
    rom[169] = 16'd28208;
    rom[170] = 16'd28310;
    rom[171] = 16'd28411;
    rom[172] = 16'd28510;
    rom[173] = 16'd28609;
    rom[174] = 16'd28706;
    rom[175] = 16'd28803;
    rom[176] = 16'd28898;
    rom[177] = 16'd28992;
    rom[178] = 16'd29085;
    rom[179] = 16'd29177;
    rom[180] = 16'd29268;
    rom[181] = 16'd29358;
    rom[182] = 16'd29447;
    rom[183] = 16'd29534;
    rom[184] = 16'd29621;
    rom[185] = 16'd29706;
    rom[186] = 16'd29791;
    rom[187] = 16'd29874;
    rom[188] = 16'd29956;
    rom[189] = 16'd30037;
    rom[190] = 16'd30117;
    rom[191] = 16'd30195;
    rom[192] = 16'd30273;
    rom[193] = 16'd30349;
    rom[194] = 16'd30424;
    rom[195] = 16'd30498;
    rom[196] = 16'd30571;
    rom[197] = 16'd30643;
    rom[198] = 16'd30714;
    rom[199] = 16'd30783;
    rom[200] = 16'd30852;
    rom[201] = 16'd30919;
    rom[202] = 16'd30985;
    rom[203] = 16'd31050;
    rom[204] = 16'd31113;
    rom[205] = 16'd31176;
    rom[206] = 16'd31237;
    rom[207] = 16'd31297;
    rom[208] = 16'd31356;
    rom[209] = 16'd31414;
    rom[210] = 16'd31470;
    rom[211] = 16'd31526;
    rom[212] = 16'd31580;
    rom[213] = 16'd31633;
    rom[214] = 16'd31685;
    rom[215] = 16'd31736;
    rom[216] = 16'd31785;
    rom[217] = 16'd31833;
    rom[218] = 16'd31880;
    rom[219] = 16'd31926;
    rom[220] = 16'd31971;
    rom[221] = 16'd32014;
    rom[222] = 16'd32057;
    rom[223] = 16'd32098;
    rom[224] = 16'd32137;
    rom[225] = 16'd32176;
    rom[226] = 16'd32213;
    rom[227] = 16'd32250;
    rom[228] = 16'd32285;
    rom[229] = 16'd32318;
    rom[230] = 16'd32351;
    rom[231] = 16'd32382;
    rom[232] = 16'd32412;
    rom[233] = 16'd32441;
    rom[234] = 16'd32469;
    rom[235] = 16'd32495;
    rom[236] = 16'd32521;
    rom[237] = 16'd32545;
    rom[238] = 16'd32567;
    rom[239] = 16'd32589;
    rom[240] = 16'd32609;
    rom[241] = 16'd32628;
    rom[242] = 16'd32646;
    rom[243] = 16'd32663;
    rom[244] = 16'd32678;
    rom[245] = 16'd32692;
    rom[246] = 16'd32705;
    rom[247] = 16'd32717;
    rom[248] = 16'd32728;
    rom[249] = 16'd32737;
    rom[250] = 16'd32745;
    rom[251] = 16'd32752;
    rom[252] = 16'd32757;
    rom[253] = 16'd32761;
    rom[254] = 16'd32765;
    rom[255] = 16'd32766;
end

// 索引倒序排列
genvar i;
generate
    for(i=0;i<$clog2(N);i=i+1)
    begin
        assign ni[i] = n[$clog2(N)-i-1];
    end
endgenerate

// bstep
always@(posedge clk)
begin
    bstep<=({1'b1,{$clog2(N){1'b0}}}>>k);
end

// data_en
always@(posedge clk)
begin
    data_en<=din_en;
end

// data_re
always@(posedge clk)
begin
    data_re<=din_re;
end

// data_im
always@(posedge clk)
begin
    data_im<=din_im;
end

// ram
always@(posedge clk)
begin
    if(wen0)
        ram[addr0]<=wdata0;
    else
        rdata0<=ram[addr0];
    if(wen1)
        ram[addr1]<=wdata1;
    else
        rdata1<=ram[addr1];
end

assign real3=real2;
assign imag3=spoint?{1'b0,{(W-1){1'b1}}}:imag2;

assign _ctrl0_ = &addr0&&wen0;
assign _ctrl1_ = !(k!=$clog2(N)-1);
assign _ctrl2_ = !(k==0);
assign _ctrl3_ = !(mmax==1);
assign _ctrl4_ = !(n<nmax+1);
assign _ctrl5_ = !(mmax==3);
assign _ctrl6_ = !(m<mmax+1);
assign _ctrl7_ = !(n!=N);
assign _ctrl8_ = n!=N-1;
assign _ctrl9_ = !busy&&start;
assign _ctrl11_ = (phase1==0);
assign _ctrl13_ = (phase1==1);
assign _ctrl15_ = (phase1==2);
assign _ctrl17_ = (phase1==3);
assign _ctrl23_ = _ctrl144_;
assign _ctrl25_ = _ctrl142_;
assign _ctrl27_ = _ctrl143_;
assign _ctrl29_ = _ctrl145_;
assign _ctrl31_ = _ctrl146_;

assign _ctrl35_ = !busy&&start;
assign _ctrl36_ = _ctrl35_;
assign _ctrl37_ = _ctrl36_;

// _ctrl38_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl38_ <= 0;
    else
        _ctrl38_ <= _ctrl123_;
end

// _ctrl39_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl39_ <= 0;
    else
        _ctrl39_ <= _ctrl124_;
end

// _ctrl40_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl40_ <= 0;
    else
        _ctrl40_ <= _ctrl39_;
end

// _ctrl41_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl41_ <= 0;
    else
        _ctrl41_ <= (_ctrl125_&&(!_ctrl1_)&&(!_ctrl2_));
end

// _ctrl42_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl42_ <= 0;
    else
        _ctrl42_ <= _ctrl126_;
end

// _ctrl43_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl43_ <= 0;
    else
        _ctrl43_ <= _ctrl127_;
end

// _ctrl44_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl44_ <= 0;
    else
        _ctrl44_ <= (_ctrl43_&&(!_ctrl3_));
end

// _ctrl45_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl45_ <= 0;
    else
        _ctrl45_ <= _ctrl44_;
end

// _ctrl46_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl46_ <= 0;
    else
        _ctrl46_ <= (_ctrl128_&&(!_ctrl4_));
end

// _ctrl47_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl47_ <= 0;
    else
        _ctrl47_ <= _ctrl46_;
end

// _ctrl48_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl48_ <= 0;
    else
        _ctrl48_ <= _ctrl47_;
end

// _ctrl49_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl49_ <= 0;
    else
        _ctrl49_ <= _ctrl48_;
end

// _ctrl50_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl50_ <= 0;
    else
        _ctrl50_ <= _ctrl49_;
end

// _ctrl51_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl51_ <= 0;
    else
        _ctrl51_ <= _ctrl50_;
end

// _ctrl52_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl52_ <= 0;
    else
        _ctrl52_ <= _ctrl51_;
end

// _ctrl53_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl53_ <= 0;
    else
        _ctrl53_ <= _ctrl52_;
end

// _ctrl54_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl54_ <= 0;
    else
        _ctrl54_ <= _ctrl53_;
end

// _ctrl55_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl55_ <= 0;
    else
        _ctrl55_ <= _ctrl54_;
end

// _ctrl56_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl56_ <= 0;
    else
        _ctrl56_ <= _ctrl55_;
end

// _ctrl57_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl57_ <= 0;
    else
        _ctrl57_ <= _ctrl56_;
end

// _ctrl58_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl58_ <= 0;
    else
        _ctrl58_ <= _ctrl57_;
end

// _ctrl59_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl59_ <= 0;
    else
        _ctrl59_ <= _ctrl58_;
end

// _ctrl60_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl60_ <= 0;
    else
        _ctrl60_ <= _ctrl59_;
end

// _ctrl61_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl61_ <= 0;
    else
        _ctrl61_ <= _ctrl60_;
end

// _ctrl62_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl62_ <= 0;
    else
        _ctrl62_ <= _ctrl61_;
end

// _ctrl63_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl63_ <= 0;
    else
        _ctrl63_ <= (_ctrl43_&&(!_ctrl5_));
end

// _ctrl64_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl64_ <= 0;
    else
        _ctrl64_ <= _ctrl63_;
end

// _ctrl65_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl65_ <= 0;
    else
        _ctrl65_ <= (_ctrl131_&&(!_ctrl4_));
end

// _ctrl66_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl66_ <= 0;
    else
        _ctrl66_ <= _ctrl65_;
end

// _ctrl67_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl67_ <= 0;
    else
        _ctrl67_ <= _ctrl66_;
end

// _ctrl68_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl68_ <= 0;
    else
        _ctrl68_ <= _ctrl67_;
end

// _ctrl69_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl69_ <= 0;
    else
        _ctrl69_ <= _ctrl68_;
end

// _ctrl70_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl70_ <= 0;
    else
        _ctrl70_ <= _ctrl69_;
end

// _ctrl71_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl71_ <= 0;
    else
        _ctrl71_ <= _ctrl70_;
end

// _ctrl72_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl72_ <= 0;
    else
        _ctrl72_ <= _ctrl71_;
end

// _ctrl73_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl73_ <= 0;
    else
        _ctrl73_ <= _ctrl72_;
end

// _ctrl74_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl74_ <= 0;
    else
        _ctrl74_ <= _ctrl73_;
end

// _ctrl75_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl75_ <= 0;
    else
        _ctrl75_ <= _ctrl74_;
end

// _ctrl76_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl76_ <= 0;
    else
        _ctrl76_ <= _ctrl75_;
end

// _ctrl77_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl77_ <= 0;
    else
        _ctrl77_ <= _ctrl76_;
end

// _ctrl78_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl78_ <= 0;
    else
        _ctrl78_ <= _ctrl77_;
end

// _ctrl79_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl79_ <= 0;
    else
        _ctrl79_ <= _ctrl78_;
end

// _ctrl80_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl80_ <= 0;
    else
        _ctrl80_ <= _ctrl79_;
end

// _ctrl81_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl81_ <= 0;
    else
        _ctrl81_ <= _ctrl80_;
end

// _ctrl82_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl82_ <= 0;
    else
        _ctrl82_ <= _ctrl133_;
end

// _ctrl83_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl83_ <= 0;
    else
        _ctrl83_ <= _ctrl82_;
end

// _ctrl84_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl84_ <= 0;
    else
        _ctrl84_ <= (_ctrl134_&&(!_ctrl4_));
end

// _ctrl85_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl85_ <= 0;
    else
        _ctrl85_ <= _ctrl84_;
end

// _ctrl86_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl86_ <= 0;
    else
        _ctrl86_ <= (_ctrl135_&&(!_ctrl6_));
end

// _ctrl87_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl87_ <= 0;
    else
        _ctrl87_ <= _ctrl86_;
end

// _ctrl88_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl88_ <= 0;
    else
        _ctrl88_ <= _ctrl87_;
end

// _ctrl89_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl89_ <= 0;
    else
        _ctrl89_ <= _ctrl88_;
end

// _ctrl90_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl90_ <= 0;
    else
        _ctrl90_ <= _ctrl89_;
end

// _ctrl91_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl91_ <= 0;
    else
        _ctrl91_ <= _ctrl90_;
end

// _ctrl92_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl92_ <= 0;
    else
        _ctrl92_ <= _ctrl91_;
end

// _ctrl93_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl93_ <= 0;
    else
        _ctrl93_ <= _ctrl92_;
end

// _ctrl94_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl94_ <= 0;
    else
        _ctrl94_ <= _ctrl93_;
end

// _ctrl95_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl95_ <= 0;
    else
        _ctrl95_ <= _ctrl94_;
end

// _ctrl96_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl96_ <= 0;
    else
        _ctrl96_ <= _ctrl95_;
end

// _ctrl97_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl97_ <= 0;
    else
        _ctrl97_ <= _ctrl96_;
end

// _ctrl98_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl98_ <= 0;
    else
        _ctrl98_ <= _ctrl97_;
end

// _ctrl99_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl99_ <= 0;
    else
        _ctrl99_ <= _ctrl98_;
end

// _ctrl100_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl100_ <= 0;
    else
        _ctrl100_ <= _ctrl99_;
end

// _ctrl101_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl101_ <= 0;
    else
        _ctrl101_ <= _ctrl100_;
end

// _ctrl102_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl102_ <= 0;
    else
        _ctrl102_ <= _ctrl136_;
end

// _ctrl103_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl103_ <= 0;
    else
        _ctrl103_ <= _ctrl102_;
end

// _ctrl104_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl104_ <= 0;
    else
        _ctrl104_ <= _ctrl137_;
end

// _ctrl105_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl105_ <= 0;
    else
        _ctrl105_ <= _ctrl104_;
end

// _ctrl106_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl106_ <= 0;
    else
        _ctrl106_ <= _ctrl138_;
end

// _ctrl107_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl107_ <= 0;
    else
        _ctrl107_ <= _ctrl106_;
end

// _ctrl108_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl108_ <= 0;
    else
        _ctrl108_ <= (_ctrl139_&&(!_ctrl7_));
end

// _ctrl109_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl109_ <= 0;
    else
        _ctrl109_ <= _ctrl108_;
end

// _ctrl110_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl110_ <= 0;
    else
        _ctrl110_ <= _ctrl109_;
end

// _ctrl111_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl111_ <= 0;
    else
        _ctrl111_ <= _ctrl110_;
end

// _ctrl112_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl112_ <= 0;
    else
        _ctrl112_ <= _ctrl111_;
end

// _ctrl113_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl113_ <= 0;
    else
        _ctrl113_ <= _ctrl112_;
end

// _ctrl114_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl114_ <= 0;
    else
        _ctrl114_ <= _ctrl113_;
end

// _ctrl115_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl115_ <= 0;
    else
        _ctrl115_ <= _ctrl114_;
end

// _ctrl116_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl116_ <= 0;
    else
        _ctrl116_ <= _ctrl140_;
end

// _ctrl117_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl117_ <= 0;
    else
        _ctrl117_ <= _ctrl116_;
end

// _ctrl118_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl118_ <= 0;
    else
        _ctrl118_ <= _ctrl141_;
end

// _ctrl119_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl119_ <= 0;
    else
        _ctrl119_ <= (_ctrl118_&&(!_ctrl8_));
end

// _ctrl120_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl120_ <= 0;
    else
        _ctrl120_ <= _ctrl119_;
end

// _ctrl121_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl121_ <= 0;
    else
        _ctrl121_ <= _ctrl120_;
end

// _ctrl122_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl122_ <= 0;
    else
        _ctrl122_ <= _ctrl121_;
end

assign _ctrl123_ = _ctrl37_||(_ctrl38_&&(!_ctrl0_));
assign _ctrl124_ = (_ctrl38_&&_ctrl0_);
assign _ctrl125_ = _ctrl40_||_ctrl105_;
assign _ctrl126_ = (_ctrl125_&&(!_ctrl1_)&&_ctrl2_);
assign _ctrl127_ = _ctrl41_||_ctrl42_;
assign _ctrl128_ = _ctrl45_||_ctrl62_;
assign _ctrl129_ = (_ctrl128_&&_ctrl4_);
assign _ctrl130_ = (_ctrl43_&&_ctrl3_);
assign _ctrl131_ = _ctrl64_||_ctrl81_;
assign _ctrl132_ = (_ctrl131_&&_ctrl4_);
assign _ctrl133_ = (_ctrl130_&&_ctrl5_);
assign _ctrl134_ = _ctrl83_||_ctrl103_;
assign _ctrl135_ = _ctrl85_||_ctrl101_;
assign _ctrl136_ = (_ctrl135_&&_ctrl6_);
assign _ctrl137_ = _ctrl129_||_ctrl132_||(_ctrl134_&&_ctrl4_);
assign _ctrl138_ = (_ctrl125_&&_ctrl1_);
assign _ctrl139_ = _ctrl107_||_ctrl115_;
assign _ctrl140_ = (_ctrl139_&&_ctrl7_);
assign _ctrl141_ = _ctrl117_||(_ctrl118_&&_ctrl8_);

assign _ctrl147_ = _ctrl38_;
assign _ctrl148_ = _ctrl232_;
assign _ctrl149_ = _ctrl38_;
assign _ctrl150_ = _ctrl228_;
assign _ctrl151_ = _ctrl226_;
assign _ctrl152_ = _ctrl227_;
assign _ctrl153_ = _ctrl86_||_ctrl237_;
assign _ctrl154_ = _ctrl108_||_ctrl238_;
assign _ctrl155_ = _ctrl220_||_ctrl221_;
assign _ctrl156_ = _ctrl38_;
assign _ctrl157_ = _ctrl234_;
assign _ctrl158_ = _ctrl213_;
assign _ctrl159_ = _ctrl39_;
assign _ctrl160_ = _ctrl104_;
assign _ctrl161_ = _ctrl43_||_ctrl119_||_ctrl25_||_ctrl27_||_ctrl239_;
assign _ctrl162_ = _ctrl41_;
assign _ctrl163_ = _ctrl42_;
assign _ctrl164_ = _ctrl41_;
assign _ctrl165_ = _ctrl42_;
assign _ctrl166_ = _ctrl41_;
assign _ctrl167_ = _ctrl42_;
assign _ctrl168_ = _ctrl44_||_ctrl63_||_ctrl82_||_ctrl106_||_ctrl116_;
assign _ctrl169_ = _ctrl240_;
assign _ctrl170_ = _ctrl241_;
assign _ctrl171_ = _ctrl102_||_ctrl118_;
assign _ctrl172_ = _ctrl242_;
assign _ctrl173_ = _ctrl46_||_ctrl65_||_ctrl84_;
assign _ctrl174_ = _ctrl229_;
assign _ctrl175_ = _ctrl243_;
assign _ctrl176_ = _ctrl227_;
assign _ctrl177_ = _ctrl230_;
assign _ctrl178_ = _ctrl118_||_ctrl230_;
assign _ctrl179_ = _ctrl228_;
assign _ctrl180_ = _ctrl226_;
assign _ctrl181_ = _ctrl227_;
assign _ctrl182_ = _ctrl86_||_ctrl237_;
assign _ctrl183_ = _ctrl108_||_ctrl238_;
assign _ctrl184_ = _ctrl220_||_ctrl221_;
assign _ctrl185_ = _ctrl118_;
assign _ctrl186_ = _ctrl228_;
assign _ctrl187_ = _ctrl231_;
assign _ctrl188_ = _ctrl233_;
assign _ctrl189_ = _ctrl86_;
assign _ctrl190_ = _ctrl232_;
assign _ctrl191_ = _ctrl234_;
assign _ctrl192_ = _ctrl213_;
assign _ctrl193_ = _ctrl84_;
assign _ctrl194_ = _ctrl244_;
assign _ctrl195_ = _ctrl245_;
assign _ctrl196_ = _ctrl118_;
assign _ctrl197_ = _ctrl9_;
assign _ctrl198_ = _ctrl246_;
assign _ctrl199_ = _ctrl11_;
assign _ctrl200_ = _ctrl13_;
assign _ctrl201_ = _ctrl15_;
assign _ctrl202_ = _ctrl17_;
assign _ctrl203_ = _ctrl11_;
assign _ctrl204_ = _ctrl13_;
assign _ctrl205_ = _ctrl15_;
assign _ctrl206_ = _ctrl17_;
assign _ctrl207_ = _ctrl23_;
assign _ctrl208_ = _ctrl31_;
assign _ctrl209_ = _ctrl31_;

// _ctrl210_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl210_ <= 0;
    else if(_ctrl54_)
        _ctrl210_ <= 1;
    else if(_ctrl62_)
        _ctrl210_ <= 0;
end

// _ctrl211_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl211_ <= 0;
    else if(_ctrl73_)
        _ctrl211_ <= 1;
    else if(_ctrl81_)
        _ctrl211_ <= 0;
end

// _ctrl212_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl212_ <= 0;
    else if(_ctrl93_)
        _ctrl212_ <= 1;
    else if(_ctrl101_)
        _ctrl212_ <= 0;
end

// _ctrl213_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl213_ <= 0;
    else if(_ctrl111_)
        _ctrl213_ <= 1;
    else if(_ctrl115_)
        _ctrl213_ <= 0;
end

// _ctrl214_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl214_ <= 0;
    else if(_ctrl66_)
        _ctrl214_ <= 1;
    else if(_ctrl69_)
        _ctrl214_ <= 0;
end

// _ctrl215_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl215_ <= 0;
    else if(_ctrl70_)
        _ctrl215_ <= 1;
    else if(_ctrl73_)
        _ctrl215_ <= 0;
end

// _ctrl216_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl216_ <= 0;
    else if(_ctrl74_)
        _ctrl216_ <= 1;
    else if(_ctrl77_)
        _ctrl216_ <= 0;
end

// _ctrl217_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl217_ <= 0;
    else if(_ctrl78_)
        _ctrl217_ <= 1;
    else if(_ctrl81_)
        _ctrl217_ <= 0;
end

// _ctrl218_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl218_ <= 0;
    else if(_ctrl86_)
        _ctrl218_ <= 1;
    else if(_ctrl93_)
        _ctrl218_ <= 0;
end

// _ctrl219_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl219_ <= 0;
    else if(_ctrl94_)
        _ctrl219_ <= 1;
    else if(_ctrl101_)
        _ctrl219_ <= 0;
end

// _ctrl220_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl220_ <= 0;
    else if(_ctrl108_)
        _ctrl220_ <= 1;
    else if(_ctrl111_)
        _ctrl220_ <= 0;
end

// _ctrl221_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl221_ <= 0;
    else if(_ctrl112_)
        _ctrl221_ <= 1;
    else if(_ctrl115_)
        _ctrl221_ <= 0;
end

// _ctrl222_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl222_ <= 0;
    else if(_ctrl46_)
        _ctrl222_ <= 1;
    else if(_ctrl54_)
        _ctrl222_ <= 0;
end

// _ctrl223_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl223_ <= 0;
    else if(_ctrl65_)
        _ctrl223_ <= 1;
    else if(_ctrl73_)
        _ctrl223_ <= 0;
end

// _ctrl224_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl224_ <= 0;
    else if((_ctrl135_&&(!_ctrl6_)))
        _ctrl224_ <= 1;
    else if(_ctrl93_)
        _ctrl224_ <= 0;
end

// _ctrl225_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl225_ <= 0;
    else if((_ctrl139_&&(!_ctrl7_)))
        _ctrl225_ <= 1;
    else if(_ctrl111_)
        _ctrl225_ <= 0;
end

assign _ctrl226_ = _ctrl214_||_ctrl215_||_ctrl216_||_ctrl217_||_ctrl218_||_ctrl219_||_ctrl236_||_ctrl247_;
assign _ctrl227_ = _ctrl248_;
assign _ctrl228_ = _ctrl235_||_ctrl249_;
assign _ctrl229_ = _ctrl235_;
assign _ctrl230_ = _ctrl222_||_ctrl223_||_ctrl224_||_ctrl225_;
assign _ctrl231_ = _ctrl236_;
assign _ctrl232_ = _ctrl210_||_ctrl211_||_ctrl212_||_ctrl213_;
assign _ctrl233_ = _ctrl214_||_ctrl215_||_ctrl218_;
assign _ctrl234_ = _ctrl210_||_ctrl211_||_ctrl212_;
assign _ctrl235_ = _ctrl250_;
assign _ctrl236_ = _ctrl251_;

assign _ctrl237_ = _ctrl94_;
assign _ctrl238_ = _ctrl112_;

// _ctrl239_ 
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl239_  <= 0;
    else
        _ctrl239_ <= _ctrl119_||_ctrl106_||_ctrl104_||_ctrl102_||_ctrl84_||_ctrl82_||_ctrl63_||_ctrl44_||_ctrl39_;
end

assign _ctrl240_ = _ctrl61_;
assign _ctrl241_ = _ctrl80_;
assign _ctrl242_ = _ctrl114_;

// _ctrl243_ 
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl243_  <= 0;
    else
        _ctrl243_ <= _ctrl65_||_ctrl46_;
end

assign _ctrl244_ = _ctrl100_;
assign _ctrl245_ = _ctrl117_;
assign _ctrl246_ = _ctrl121_;

// _ctrl247_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl247_ <= 0;
    else
        _ctrl247_ <= _ctrl61_||_ctrl59_||_ctrl57_||_ctrl55_;
end

// _ctrl248_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl248_ <= 0;
    else
        _ctrl248_ <= _ctrl77_||_ctrl73_||_ctrl60_||_ctrl58_||_ctrl56_||_ctrl54_;
end

assign _ctrl249_ = _ctrl70_;

// _ctrl250_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl250_ <= 0;
    else
        _ctrl250_ <= _ctrl65_||_ctrl52_||_ctrl50_||_ctrl48_||_ctrl46_;
end

// _ctrl251_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl251_ <= 0;
    else
        _ctrl251_ <= _ctrl53_||_ctrl51_||_ctrl49_||_ctrl47_;
end

// wen0
always@(posedge clk)
begin
    case(1)
        _ctrl147_ : wen0<=data_en;
        _ctrl148_ : wen0<=1;
        default : wen0<=0;
    endcase
end

// addr0
always@(posedge clk, posedge rst)
begin
    if(rst)
        addr0<=0;
    else case(1)
        _ctrl149_ : addr0<=addr0+wen0;
        _ctrl150_ : addr0<=base0;
        _ctrl151_ : addr0<=addr0+1;
        _ctrl152_ : addr0<=base1;
        _ctrl153_ : addr0<=base0+m;
        _ctrl154_ : addr0<=n;
        _ctrl155_ : addr0<=addr0+2;
        _ctrl198_ : addr0<=0;
    endcase
end

// wdata0
always@(posedge clk)
begin
    case(1)
        _ctrl156_ : wdata0<={{$clog2(N){data_im[W-1]}},data_im,{$clog2(N){data_re[W-1]}},data_re};
        _ctrl157_ : wdata0<={imag16,real16};
        _ctrl158_ : wdata0<={imag12,real12};
    endcase
end

// k
always@(posedge clk)
begin
    case(1)
        _ctrl159_ : k<=0;
        _ctrl160_ : k<=k+1;
    endcase
end

// nmax
always@(posedge clk)
begin
    case(1)
        _ctrl162_ : nmax<=0;
        _ctrl163_ : nmax<={nmax,1'b1};
    endcase
end

// mmax
always@(posedge clk)
begin
    case(1)
        _ctrl164_ : mmax<=N/2-1;
        _ctrl165_ : mmax<=mmax>>1;
    endcase
end

// offset
always@(posedge clk)
begin
    case(1)
        _ctrl166_ : offset<=N/2;
        _ctrl167_ : offset<=offset>>1;
    endcase
end

// n
always@(posedge clk)
begin
    case(1)
        _ctrl168_ : n<=0;
        _ctrl169_ : n<=n+4;
        _ctrl170_ : n<=n+2;
        _ctrl171_ : n<=n+1;
        _ctrl172_ : n<=n+8;
    endcase
end

// base0
always@(posedge clk)
begin
    case(1)
        _ctrl173_ : base0<={n[$clog2(N)-3:0],{$clog2(N){1'b0}}}>>k;
        _ctrl174_ : base0<=base0+bstep;
    endcase
end

// base1
always@(posedge clk)
begin
    case(1)
        _ctrl175_ : base1<=base0;
        _ctrl176_ : base1<=base1+bstep;
    endcase
end

// addr1
always@(posedge clk, posedge rst)
begin
    if(rst)
        addr1<=0;
    else case(1)
        _ctrl179_ : addr1<=base0+offset;
        _ctrl180_ : addr1<=addr1+1;
        _ctrl181_ : addr1<=base1+offset;
        _ctrl182_ : addr1<=base0+m+offset;
        _ctrl183_ : addr1<=n+1;
        _ctrl184_ : addr1<=addr1+2;
        _ctrl185_ : addr1<=ni;
    endcase
end

// mm
always@(posedge clk)
begin
    case(1)
        _ctrl186_ : mm<=0;
        _ctrl187_ : mm<=1;
        _ctrl188_ : mm<=mm+1;
        _ctrl189_ : mm<=m;
    endcase
end

// addr2
always@(posedge clk, posedge rst)
begin
    if(rst)
        addr2<=0;
    else
        addr2<=mm<<k;
end

// imag0
always@(posedge clk)
begin
    {imag0,real0}<=rdata0;
end

// imag1
always@(posedge clk)
begin
    {imag1,real1}<=rdata1;
end

// phase0
always@(posedge clk)
begin
    phase0<=addr2[$clog2(N)-1:$clog2(N)-2];
end

// addr3
always@(posedge clk, posedge rst)
begin
    if(rst)
        addr3<=0;
    else
        addr3<=addr2[$clog2(N)-3:0];
end

// addr4
always@(posedge clk, posedge rst)
begin
    if(rst)
        addr4<=0;
    else
        addr4<=N/4-addr2[$clog2(N)-3:0];
end

// phase1
always@(posedge clk)
begin
    phase1<=phase0;
end

// real2
always@(posedge clk)
begin
    real2<=rom[addr3[$clog2(N)-3:0]];
end

// imag2
always@(posedge clk)
begin
    imag2<=rom[addr4[$clog2(N)-3:0]];
end

// spoint
always@(posedge clk)
begin
    spoint<=addr4==N/4;
end

// real12
always@(posedge clk)
begin
    real12<=$signed(real0)+$signed(real1);
end

// imag12
always@(posedge clk)
begin
    imag12<=$signed(imag0)+$signed(imag1);
end

// real4
always@(posedge clk)
begin
    real4<=$signed(real0)-$signed(real1);
end

// imag4
always@(posedge clk)
begin
    imag4<=$signed(imag0)-$signed(imag1);
end

// real13
always@(posedge clk)
begin
    real13<=real12;
end

// imag13
always@(posedge clk)
begin
    imag13<=imag12;
end

// real6
always@(posedge clk)
begin
    real6<=real4;
end

// imag6
always@(posedge clk)
begin
    imag6<=imag4;
end

// real14
always@(posedge clk)
begin
    real14<=real13;
end

// imag14
always@(posedge clk)
begin
    imag14<=imag13;
end

// real7
always@(posedge clk)
begin
    real7<=$signed(real5)*$signed(real6);
end

// imag7
always@(posedge clk)
begin
    imag7<=$signed(imag5)*$signed(real6);
end

// real8
always@(posedge clk)
begin
    real8<=$signed(imag5)*$signed(imag6);
end

// imag8
always@(posedge clk)
begin
    imag8<=$signed(real5)*$signed(imag6);
end

// real15
always@(posedge clk)
begin
    real15<=real14;
end

// imag15
always@(posedge clk)
begin
    imag15<=imag14;
end

// real9
always@(posedge clk)
begin
    real9<=real7[2*W+$clog2(N)-2:W-1];
end

// imag9
always@(posedge clk)
begin
    imag9<=imag7[2*W+$clog2(N)-2:W-1];
end

// real10
always@(posedge clk)
begin
    real10<=real8[2*W+$clog2(N)-2:W-1];
end

// imag10
always@(posedge clk)
begin
    imag10<=imag8[2*W+$clog2(N)-2:W-1];
end

// real16
always@(posedge clk)
begin
    real16<=real15;
end

// imag16
always@(posedge clk)
begin
    imag16<=imag15;
end

// real11
always@(posedge clk)
begin
    real11<=$signed(real9)-$signed(real10);
end

// imag11
always@(posedge clk)
begin
    imag11<=$signed(imag9)+$signed(imag10);
end

// wen1
always@(posedge clk)
begin
    if(_ctrl190_)
        wen1<=1;
    else
        wen1<=0;
end

// wdata1
always@(posedge clk)
begin
    case(1)
        _ctrl191_ : wdata1<={imag11,real11};
        _ctrl192_ : wdata1<={imag4,real4};
    endcase
end

// m
always@(posedge clk)
begin
    case(1)
        _ctrl193_ : m<=0;
        _ctrl194_ : m<=m+8;
    endcase
end

// _ctrl142_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl142_<=0;
    else if(_ctrl195_)
        _ctrl142_<=1;
    else
        _ctrl142_<=0;
end

// _ctrl143_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl143_<=0;
    else
        _ctrl143_<=_ctrl142_;
end

// _ctrl144_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl144_<=0;
    else
        _ctrl144_<=_ctrl143_;
end

// _ctrl145_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl145_<=0;
    else if(_ctrl196_)
        _ctrl145_<=1;
    else
        _ctrl145_<=0;
end

// _ctrl146_
always@(posedge clk, posedge rst)
begin
    if(rst)
        _ctrl146_<=0;
    else
        _ctrl146_<=_ctrl145_;
end

// busy
always@(posedge clk, posedge rst)
begin
    if(rst)
        busy<=0;
    else if(_ctrl197_)
        busy<=1;
    else if(_ctrl198_)
        busy<=0;
end

// imag5
always@(posedge clk)
begin
    case(1)
        _ctrl199_ : imag5<=mode?real3:~real3;
        _ctrl200_ : imag5<=mode?imag3:~imag3;
        _ctrl201_ : imag5<=mode?~real3:real3;
        _ctrl202_ : imag5<=mode?~imag3:imag3;
    endcase
end

// real5
always@(posedge clk)
begin
    case(1)
        _ctrl203_ : real5<=imag3;
        _ctrl204_ : real5<=~real3;
        _ctrl205_ : real5<=~imag3;
        _ctrl206_ : real5<=real3;
    endcase
end

// done
always@(posedge clk)
begin
    if(_ctrl207_)
        done<=1;
    else
        done<=0;
end

// dout_en
always@(posedge clk)
begin
    if(_ctrl208_)
        dout_en<=1;
    else
        dout_en<=0;
end

// dout_im
always@(posedge clk)
begin
    if(_ctrl209_)
        {dout_im,dout_re}<=rdata1;
end
`pragma protect end

endmodule
