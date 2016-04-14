/* file: Bzip2Compressor.java */
/*******************************************************************************
* Copyright 2014-2016 Intel Corporation
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

package com.intel.daal.data_management.compression.bzip2;

import com.intel.daal.data_management.compression.CompressionMethod;
import com.intel.daal.data_management.compression.Compressor;
import com.intel.daal.services.DaalContext;

/**
 * <a name="DAAL-CLASS-SERVICE__COMPRESSION__BZIP2__BZIP2COMPRESSOR"></a>
 *
 * @brief Implementation of the Compressor class for the BZIP2 compression method
 *
 * @par References
 *      - <a href="DAAL-REF-COMPRESSION">Data compression usage model</a>
 *      - @ref Bzip2CompressionParameter class
 */
public class Bzip2Compressor extends Compressor {
    public Bzip2CompressionParameter parameter; /*!< BZIP2 compression parameters */

    /** @private */
    static {
        System.loadLibrary("JavaAPI");
    }

    /**
    * Bzip2Compressor constructor
    */
    public Bzip2Compressor(DaalContext context) {
        super(context, CompressionMethod.bzip2);
        parameter = new Bzip2CompressionParameter(context,
                cInitParameter(this.cObject, CompressionMethod.bzip2.getValue()));
    }
}