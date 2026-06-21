module bubble_remove #(
    parameter int N = 4,
    parameter int DW = 8
) (
    input  [N-1:0]           mask,
    input  [N-1:0][DW-1:0]   mask_data,
    output logic [N-1:0]           sorted_mask,
    output logic [N-1:0][DW-1:0]   sorted_mask_data
);

    // 中间信号：用于生成紧凑后的索引
    logic [N-1:0][$clog2(N+1)-1:0] idx;   // idx[i] 表示第 i 个有效数据应放到的目标位置
    logic [N-1:0]                  valid_sel;

    // 计算每个位置“前面有效位数” = 目标索引
    // idx[i] = mask[0] + mask[1] + ... + mask[i-1]
    always_comb begin
        idx[0] = '0;
        for (int i = 1; i < N; i++) begin
            idx[i] = idx[i-1] + mask[i-1];   // 此处 idx[i] 的位宽足以容纳和，无需担心溢出
        end
    end

    // 根据索引反向选择：对于每个输出位置 j，找到对应的输入 i
    always_comb begin
        sorted_mask = '0;
        sorted_mask_data = '0;
        for (int i = 0; i < N; i++) begin
            if (mask[i]) begin
                sorted_mask_data[idx[i]] = mask_data[i];
                sorted_mask[idx[i]]      = 1'b1;
            end
        end
    end

endmodule