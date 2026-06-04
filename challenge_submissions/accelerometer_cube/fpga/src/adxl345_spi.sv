// ADXL345 reader for the DE10-Lite onboard accelerometer.
// SPI mode 3: SCLK idles high, MOSI changes after sample edges,
// MISO is sampled on rising SCLK edges.

module adxl345_spi #(
    parameter CLK_FREQ  = 50_000_000,
    parameter SPI_HZ    = 1_000_000,
    parameter SAMPLE_HZ = 30
)(
    input  logic clk,
    input  logic rst_n,

    output logic gsensor_sclk,
    output logic gsensor_sdi,
    input  logic gsensor_sdo,
    output logic gsensor_cs_n,

    output logic signed [15:0] x_raw,
    output logic signed [15:0] y_raw,
    output logic signed [15:0] z_raw,
    output logic               sample_valid,
    output logic               init_done,
    output logic               devid_ok,
    output logic [7:0]         devid,
    output logic [3:0]         state_debug
);

    localparam HALF_DIV     = CLK_FREQ / (SPI_HZ * 2);
    localparam POWERUP_WAIT = CLK_FREQ / 100;       // 10 ms
    localparam SAMPLE_WAIT  = CLK_FREQ / SAMPLE_HZ;
    localparam GAP_WAIT     = CLK_FREQ / 100_000;   // 10 us

    localparam TXN_READ_DEVID = 3'd0;
    localparam TXN_DATA_FMT   = 3'd1;
    localparam TXN_BW_RATE    = 3'd2;
    localparam TXN_POWER_CTL  = 3'd3;
    localparam TXN_READ_AXES  = 3'd4;

    localparam ST_POWERUP = 4'd0;
    localparam ST_START   = 4'd1;
    localparam ST_LOW     = 4'd2;
    localparam ST_HIGH    = 4'd3;
    localparam ST_END     = 4'd4;
    localparam ST_GAP     = 4'd5;
    localparam ST_WAIT    = 4'd6;

    logic [3:0]  state;
    logic [2:0]  txn;
    logic [2:0]  txn_len;
    logic [2:0]  byte_idx;
    logic [2:0]  bit_idx;
    logic [7:0]  tx_byte;
    logic [7:0]  next_tx_byte;
    logic [7:0]  rx_shift;
    logic [15:0] half_cnt;
    logic [25:0] wait_cnt;
    logic [7:0]  rx0, rx1, rx2, rx3, rx4, rx5, rx6;
    logic        heartbeat;

    assign state_debug = state;

    function automatic [2:0] length_for_txn(input [2:0] t);
        begin
            case (t)
                TXN_READ_AXES: length_for_txn = 3'd7;
                default:       length_for_txn = 3'd2;
            endcase
        end
    endfunction

    function automatic [7:0] byte_for_txn(input [2:0] t, input [2:0] idx);
        begin
            case (t)
                TXN_READ_DEVID: byte_for_txn = (idx == 3'd0) ? 8'h80 : 8'h00;
                TXN_DATA_FMT:   byte_for_txn = (idx == 3'd0) ? 8'h31 : 8'h08;
                TXN_BW_RATE:    byte_for_txn = (idx == 3'd0) ? 8'h2C : 8'h0A;
                TXN_POWER_CTL:  byte_for_txn = (idx == 3'd0) ? 8'h2D : 8'h08;
                TXN_READ_AXES:  byte_for_txn = (idx == 3'd0) ? 8'hF2 : 8'h00;
                default:        byte_for_txn = 8'h00;
            endcase
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_POWERUP;
            txn          <= TXN_READ_DEVID;
            txn_len      <= 3'd2;
            byte_idx     <= 3'd0;
            bit_idx      <= 3'd7;
            tx_byte      <= 8'h00;
            next_tx_byte <= 8'h00;
            rx_shift     <= 8'h00;
            half_cnt     <= 16'd0;
            wait_cnt     <= 26'd0;
            rx0          <= 8'h00;
            rx1          <= 8'h00;
            rx2          <= 8'h00;
            rx3          <= 8'h00;
            rx4          <= 8'h00;
            rx5          <= 8'h00;
            rx6          <= 8'h00;
            x_raw        <= 16'sd0;
            y_raw        <= 16'sd0;
            z_raw        <= 16'sd0;
            sample_valid <= 1'b0;
            init_done    <= 1'b0;
            devid_ok     <= 1'b0;
            devid        <= 8'h00;
            heartbeat    <= 1'b0;
            gsensor_sclk <= 1'b1;
            gsensor_sdi  <= 1'b0;
            gsensor_cs_n <= 1'b1;
        end else begin
            sample_valid <= 1'b0;

            case (state)
                ST_POWERUP: begin
                    gsensor_cs_n <= 1'b1;
                    gsensor_sclk <= 1'b1;
                    if (wait_cnt == POWERUP_WAIT - 1) begin
                        wait_cnt <= 26'd0;
                        txn      <= TXN_READ_DEVID;
                        state    <= ST_START;
                    end else begin
                        wait_cnt <= wait_cnt + 26'd1;
                    end
                end

                ST_START: begin
                    txn_len      <= length_for_txn(txn);
                    byte_idx     <= 3'd0;
                    bit_idx      <= 3'd7;
                    tx_byte      <= byte_for_txn(txn, 3'd0);
                    next_tx_byte <= byte_for_txn(txn, 3'd0);
                    rx_shift     <= 8'h00;
                    half_cnt     <= 16'd0;
                    gsensor_cs_n <= 1'b0;
                    gsensor_sclk <= 1'b1;
                    gsensor_sdi  <= byte_for_txn(txn, 3'd0) >> 7;
                    state        <= ST_LOW;
                end

                ST_LOW: begin
                    if (half_cnt == HALF_DIV - 1) begin
                        half_cnt     <= 16'd0;
                        gsensor_sclk <= 1'b0;
                        state        <= ST_HIGH;
                    end else begin
                        half_cnt <= half_cnt + 16'd1;
                    end
                end

                ST_HIGH: begin
                    if (half_cnt == HALF_DIV - 1) begin
                        half_cnt     <= 16'd0;
                        gsensor_sclk <= 1'b1;
                        rx_shift     <= {rx_shift[6:0], gsensor_sdo};

                        if (bit_idx == 3'd0) begin
                            case (byte_idx)
                                3'd0: rx0 <= {rx_shift[6:0], gsensor_sdo};
                                3'd1: rx1 <= {rx_shift[6:0], gsensor_sdo};
                                3'd2: rx2 <= {rx_shift[6:0], gsensor_sdo};
                                3'd3: rx3 <= {rx_shift[6:0], gsensor_sdo};
                                3'd4: rx4 <= {rx_shift[6:0], gsensor_sdo};
                                3'd5: rx5 <= {rx_shift[6:0], gsensor_sdo};
                                3'd6: rx6 <= {rx_shift[6:0], gsensor_sdo};
                                default: ;
                            endcase

                            if (byte_idx == txn_len - 1) begin
                                state <= ST_END;
                            end else begin
                                byte_idx <= byte_idx + 3'd1;
                                bit_idx  <= 3'd7;
                                next_tx_byte <= byte_for_txn(txn, byte_idx + 3'd1);
                                tx_byte      <= byte_for_txn(txn, byte_idx + 3'd1);
                                gsensor_sdi  <= byte_for_txn(txn, byte_idx + 3'd1) >> 7;
                                rx_shift <= 8'h00;
                                state    <= ST_LOW;
                            end
                        end else begin
                            bit_idx     <= bit_idx - 3'd1;
                            gsensor_sdi <= tx_byte[bit_idx - 3'd1];
                            state       <= ST_LOW;
                        end
                    end else begin
                        half_cnt <= half_cnt + 16'd1;
                    end
                end

                ST_END: begin
                    gsensor_cs_n <= 1'b1;
                    gsensor_sclk <= 1'b1;
                    gsensor_sdi  <= 1'b0;
                    wait_cnt     <= 26'd0;

                    case (txn)
                        TXN_READ_DEVID: begin
                            devid    <= rx1;
                            devid_ok <= (rx1 == 8'hE5);
                            txn      <= TXN_DATA_FMT;
                            state    <= ST_GAP;
                        end
                        TXN_DATA_FMT: begin
                            txn   <= TXN_BW_RATE;
                            state <= ST_GAP;
                        end
                        TXN_BW_RATE: begin
                            txn   <= TXN_POWER_CTL;
                            state <= ST_GAP;
                        end
                        TXN_POWER_CTL: begin
                            init_done <= 1'b1;
                            state     <= ST_WAIT;
                        end
                        TXN_READ_AXES: begin
                            x_raw        <= {rx2, rx1};
                            y_raw        <= {rx4, rx3};
                            z_raw        <= {rx6, rx5};
                            heartbeat    <= ~heartbeat;
                            sample_valid <= 1'b1;
                            state        <= ST_WAIT;
                        end
                        default: begin
                            txn   <= TXN_READ_DEVID;
                            state <= ST_GAP;
                        end
                    endcase
                end

                ST_GAP: begin
                    if (wait_cnt == GAP_WAIT - 1) begin
                        wait_cnt <= 26'd0;
                        state    <= ST_START;
                    end else begin
                        wait_cnt <= wait_cnt + 26'd1;
                    end
                end

                ST_WAIT: begin
                    if (wait_cnt == SAMPLE_WAIT - 1) begin
                        wait_cnt <= 26'd0;
                        txn      <= TXN_READ_AXES;
                        state    <= ST_START;
                    end else begin
                        wait_cnt <= wait_cnt + 26'd1;
                    end
                end

                default: begin
                    state <= ST_POWERUP;
                end
            endcase
        end
    end

endmodule
