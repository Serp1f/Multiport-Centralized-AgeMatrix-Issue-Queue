// 采用递归实现的加法器数,输入的位宽就只等于1，不然sum的位宽计算有些问题
module vector_sumer #(
    parameter   WIDTH = 4
) (
    input   [WIDTH-1:0]     vec,
    output  [$clog2(WIDTH+1)-1:0]     sum
);


    generate
        // 边界为1,2
        if(WIDTH == 1) begin: genblk_n_eq_1
            assign sum = vec;
        end
        else if(WIDTH == 2) begin: genblk_n_eq_2
            assign sum = vec[0] + vec[1];
        end
        // 递归开始
        else begin: genblk_n_gt_2
            localparam M = WIDTH / 2; 
            wire [$clog2(M+1)-1:0]  sum0;
            wire [$clog2(WIDTH-M+1)-1:0]  sum1;

            vector_sumer #(M) u_sumer0
            (
                .vec(vec[M-1:0]),
                .sum(sum0)
            );

            vector_sumer #(WIDTH-M) u_sumer1
            (
                .vec(vec[WIDTH-1:M]),
                .sum(sum1)
            );
            assign  sum = sum0 + sum1;
        end

    endgenerate
    
endmodule