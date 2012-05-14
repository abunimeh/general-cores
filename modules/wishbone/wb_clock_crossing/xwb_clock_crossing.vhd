library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.wishbone_pkg.all;
use work.gencores_pkg.all;

entity xwb_clock_crossing is
   generic(
      sync_depth : natural := 2;
      log2fifo   : natural := 4);
   port(
      -- Common wishbone signals
      rst_n_i      : in  std_logic;
      -- Slave control port
      slave_clk_i  : in  std_logic;
      slave_i      : in  t_wishbone_slave_in;
      slave_o      : out t_wishbone_slave_out;
      -- Master reader port
      master_clk_i : in  std_logic;
      master_i     : in  t_wishbone_master_in;
      master_o     : out t_wishbone_master_out);
end xwb_clock_crossing;

architecture rtl of xwb_clock_crossing is
   constant mCYC_start : natural := 0;
   constant mCYC_end   : natural := mCYC_start;
   constant mWE_start  : natural := mCYC_end + 1;
   constant mWE_end    : natural := mWE_start;
   constant mADR_start : natural := mWE_end + 1;
   constant mADR_end   : natural := mADR_start + c_wishbone_address_width - 1;
   constant mDAT_start : natural := mADR_end + 1;
   constant mDAT_end   : natural := mDAT_start + c_wishbone_data_width - 1;
   constant mSEL_start : natural := mDAT_end + 1;
   constant mSEL_end   : natural := mSEL_start + (c_wishbone_data_width/8) - 1;
   constant mlen       : natural := mSEL_end + 1;
   
   signal msend, mrecv : t_wishbone_master_out;
   signal msend_vect, mrecv_vect : std_logic_vector(mlen-1 downto 0);
   signal mw_rdy, mw_en, mr_rdy, mr_en : std_logic;
   
   constant sACK_start : natural := 0;
   constant sACK_end   : natural := sACK_start;
   constant sRTY_start : natural := sACK_end + 1;
   constant sRTY_end   : natural := sRTY_start;
   constant sERR_start : natural := sRTY_end + 1;
   constant sERR_end   : natural := sERR_start;
   constant sDAT_start : natural := sERR_end + 1;
   constant sDAT_end   : natural := sDAT_start + c_wishbone_data_width - 1;
   constant slen       : natural := sDAT_end + 1;
   
   signal ssend, srecv : t_wishbone_slave_out;
   signal ssend_vect, srecv_vect : std_logic_vector(slen-1 downto 0);
   signal sw_rdy, sw_en, sr_rdy, sr_en, sa_rdy, sa_en : std_logic;
   
   signal slave_CYC : std_logic;
   signal master_o_STB : std_logic;
   signal slave_o_PUSH : std_logic;
begin
   mfifo : gc_wfifo
      generic map(addr_width => log2fifo, data_width => mlen, sync_depth => sync_depth, gray_code => true)
      port map(w_clk_i => slave_clk_i,  w_rdy_o => mw_rdy, w_en_i => mw_en, w_data_i => msend_vect,
               r_clk_i => master_clk_i, r_rdy_o => mr_rdy, r_en_i => mr_en, r_data_o => mrecv_vect,
               a_clk_i => '0', a_rdy_o => open, a_en_i => '0', rst_n_i => rst_n_i);

   msend_vect(mCYC_start) <= msend.CYC;
   msend_vect(mWE_start) <= msend.WE;
   msend_vect(mADR_end downto mADR_start) <= msend.ADR;
   msend_vect(mDAT_end downto mDAT_start) <= msend.DAT;
   msend_vect(mSEL_end downto mSEL_start) <= msend.SEL;
   
   mrecv.CYC <= mrecv_vect(mCYC_start);
   mrecv.WE  <= mrecv_vect(mWE_start);
   mrecv.ADR <= mrecv_vect(mADR_end downto mADR_start);
   mrecv.DAT <= mrecv_vect(mDAT_end downto mDAT_start);
   mrecv.SEL <= mrecv_vect(mSEL_end downto mSEL_start);
   
   sfifo : gc_wfifo
      generic map(addr_width => log2fifo, data_width => slen, sync_depth => sync_depth, gray_code => true)
      port map(w_clk_i => master_clk_i, w_rdy_o => open,   w_en_i => sw_en, w_data_i => ssend_vect,
               r_clk_i => slave_clk_i,  r_rdy_o => sr_rdy, r_en_i => sr_en, r_data_o => srecv_vect,
               a_clk_i => slave_clk_i,  a_rdy_o => sa_rdy, a_en_i => sa_en, rst_n_i => rst_n_i);
   
   ssend_vect(sACK_start) <= ssend.ACK;
   ssend_vect(sRTY_start) <= ssend.RTY;
   ssend_vect(sERR_start) <= ssend.ERR;
   ssend_vect(sDAT_end downto sDAT_start) <= ssend.DAT;
   
   srecv.ACK <= srecv_vect(sACK_start);
   srecv.RTY <= srecv_vect(sRTY_start);
   srecv.ERR <= srecv_vect(sERR_start);
   srecv.DAT <= srecv_vect(sDAT_end downto sDAT_start);

   -- Slave clock domain: slave -> mFIFO
   mw_en <= (mw_rdy and sa_rdy and slave_i.CYC and slave_i.STB) or 
            (not slave_i.CYC and slave_CYC); -- Masters may only drop cycle if FIFOs are empty
   sa_en <= mw_rdy and sa_rdy and slave_i.CYC and slave_i.STB;
   slave_o.STALL <= not mw_rdy or not sa_rdy;
   msend.CYC <= slave_i.CYC;
   msend.ADR <= slave_i.ADR;
   msend.WE  <= slave_i.WE;
   msend.SEL <= slave_i.SEL;
   msend.DAT <= slave_i.DAT;
   
   -- Master clock domain: mFIFO -> master
   mr_en <= mr_rdy and (not mrecv.CYC or not master_o_STB or not master_i.STALL);
   master_o.CYC <= mrecv.CYC;
   master_o.STB <= master_o_STB; -- is high outside of CYC. that's ok; it should be ignored.
   master_o.ADR <= mrecv.ADR;
   master_o.WE  <= mrecv.WE;
   master_o.SEL <= mrecv.SEL;
   master_o.DAT <= mrecv.DAT;
   
   drive_master_port : process(master_clk_i)
   begin
      if rising_edge(master_clk_i) then
         if rst_n_i = '0' then
            master_o_STB <= '0';
         else
            master_o_STB <= mr_en or (mrecv.CYC and master_o_STB and master_i.STALL);
         end if;
      end if;
   end process;
   
   -- Master clock domain: master -> sFIFO
   sw_en <= mrecv.CYC and (master_i.ACK or master_i.ERR or master_i.RTY);
   ssend.ACK <= master_i.ACK;
   ssend.ERR <= master_i.ERR;
   ssend.RTY <= master_i.RTY;
   ssend.DAT <= master_i.DAT;
   
   -- Slave clock domain: sFIFO -> slave
   sr_en <= sr_rdy;
   slave_o.DAT <= srecv.DAT;
   slave_o.ACK <= srecv.ACK and slave_o_PUSH;
   slave_o.RTY <= srecv.RTY and slave_o_PUSH;
   slave_o.ERR <= srecv.ERR and slave_o_PUSH;
   
   drive_slave_port : process(slave_clk_i)
   begin
      if rising_edge(slave_clk_i) then
         if rst_n_i = '0' then
            slave_o_PUSH <= '0';
            slave_CYC <= '0';
         else
            slave_o_PUSH <= sr_en;
            slave_CYC <= slave_i.CYC;
         end if;
      end if;
   end process;
end rtl;