// 选择信号sel以热独码，N-to-1
module mux_one_hot #(
    parameter   N = 8,
    parameter   WIDTH = 1
) (
    input   [N*WIDTH-1:0]   mux_in,
    input   [N-1:0] sel,
    output  [WIDTH-1:0] mux_out
);

    generate
        if(N==1) begin: genblk_N_eq1
            assign mux_out = mux_in & {WIDTH{sel[0]}};
        end        
        else if(N==2) begin:    genblk_N_eq2
            assign  mux_out = ({WIDTH{sel[1]}} & mux_in[2*WIDTH-1:WIDTH]) | ({WIDTH{sel[0]}} & mux_in[WIDTH-1:0]);
        end
        else begin: genblk_N_gt2
            localparam M = N / 2;
            wire    [WIDTH-1:0] mux0,mux1;
            
            mux_one_hot #(.N(M),.WIDTH(WIDTH)) u_mux0
            (
                .mux_in(mux_in[M*WIDTH-1:0]),
                .sel(sel[M-1:0]),
                .mux_out(mux0)
            );

            mux_one_hot #(.N(N-M),.WIDTH(WIDTH)) u_mux1
            (
                .mux_in(mux_in[N*WIDTH-1:M*WIDTH]),
                .sel(sel[N-1:M]),
                .mux_out(mux1)
            );

            assign  mux_out = mux0 | mux1;  // 不必用sel控制，如果哪边|sel == 0，哪边的mux结果就是0
        end
    endgenerate
    
endmodule