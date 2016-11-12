defmodule TM.Mercury.Tag.Type.Gen2 do
  import TM.Mercury.Utils.Binary
  use Bitwise

  def parse({<<bit_len :: uint16, tail :: binary>>, result}) do
    epc_byte_len = bytes_for_bits(bit_len) - 4
    <<pc0, pc1, tail :: binary>> = tail

    epc_byte_len =
      if (pc0 &&& 0x02) == 0x02 do
        <<pc2, pc3, tail :: binary>> = tail
        epc_byte_len = epc_byte_len - 2

          if (pc2 &&& 0x80) == 0x80 do
            <<pc4, pc5, tail :: binary>> = tail
            epc_byte_len - 2
          else
            epc_byte_len
          end
      else
        epc_byte_len
      end

    <<epc :: binary-unit(8)-size(epc_byte_len), crc :: uint16, tail :: binary>> = tail
    result =
      result
      |> Keyword.put(:epc, epc)
      |> Keyword.put(:epc_crc, crc)
    {tail, result}
  end

end
