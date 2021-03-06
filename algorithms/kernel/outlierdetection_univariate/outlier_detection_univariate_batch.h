/* file: outlier_detection_univariate_batch.h */
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

/*
//++
//  Outlier Detection algorithm parameter structure
//--
*/

#ifndef __OUTLIERDETECTION_UNIVARIATE_BATCH_H__
#define __OUTLIERDETECTION_UNIVARIATE_BATCH_H__

#include "outlier_detection_univariate_types.h"

namespace daal
{
namespace algorithms
{
namespace univariate_outlier_detection
{
namespace interface1
{

/**
 * Registers user-allocated memory to store univariate outlier detection results
 * \param[in] input   Pointer to the %input objects for the algorithm
 * \param[in] parameter     Pointer to the parameters of the algorithm
 * \param[in] method  univariate outlier detection computation method
 */
template <typename algorithmFPType>
DAAL_EXPORT void Result::allocate(const daal::algorithms::Input *input, const daal::algorithms::Parameter *parameter, const int method)
{
    Input *algInput = static_cast<Input *>(const_cast<daal::algorithms::Input *>(input));
    size_t nFeatures = algInput->get(data)->getNumberOfColumns();
    size_t nVectors  = algInput->get(data)->getNumberOfRows();
    Argument::set(weights, data_management::SerializationIfacePtr(
                      new data_management::HomogenNumericTable<algorithmFPType>(nFeatures, nVectors,
                                                                                data_management::NumericTable::doAllocate)));
}

} // namespace interface1
} // namespace univariate_outlier_detection
} // namespace algorithms
} // namespace daal

#endif
